# frozen_string_literal: true

# Also runnable inside woods-testbed with a booted application's connection.
module WoodsConsoleDialectContract
  def self.verify!(connection)
    require 'woods/console/embedded_executor'
    gate = Woods::Console::TableGate.new(blocked_tables: ['information_schema.tables'], model_tables: {})
    context = Woods::Console::SafeContext.new(connection: connection, redacted_columns: ['secret'])
    executor = Woods::Console::EmbeddedExecutor.new(
      model_validator: Woods::Console::ModelValidator.new(registry: {}), safe_context: context,
      connection: connection, read_tools_enabled: true, table_gate: gate
    )
    mysql = connection.adapter_name.downcase.include?('mysql')
    queries = {
      'SELECT 1 AS harmless' => true,
      'SELECT 1 FROM information_schema.tables LIMIT 1' => false,
      'SELECT 1 FROM information_schema . tables LIMIT 1' => false,
      'SELECT 1 FROM information_schema/**/./**/tables LIMIT 1' => false,
      'SELECT 1--1 FROM information_schema.tables LIMIT 1' => !mysql
    }
    queries.each { |sql, permitted| assert_request!(executor, sql, permitted) }
    verify_mysql_modes!(connection, executor) if mysql
    :passed
  end

  def self.assert_request!(executor, sql, permitted)
    result = executor.send_request('tool' => 'sql', 'params' => { 'sql' => sql })
    correct = permitted ? result['ok'] == true : result['error_type'] == 'validation'
    raise "Console contract failed for #{sql}: #{result.inspect}" unless correct
  end

  def self.verify_mysql_modes!(connection, executor)
    previous = connection.select_value('SELECT @@SESSION.sql_mode')
    raise 'Unexpected sql_mode characters' unless previous.match?(/\A[A-Z0-9_,]*\z/)

    ['', 'ANSI_QUOTES', 'NO_BACKSLASH_ESCAPES', 'ANSI_QUOTES,NO_BACKSLASH_ESCAPES'].each do |mode|
      connection.execute("SET SESSION sql_mode = '#{mode}'")
      mysql_mode_queries(mode).each { |sql| assert_request!(executor, sql, false) }
      assert_request!(executor, 'SELECT 1--1 AS harmless', true)
      assert_request!(executor, "SELECT 'customer''s request for update' AS body", true)
      unless mode.include?('NO_BACKSLASH_ESCAPES')
        assert_request!(executor, %q(SELECT 'customer\'s request for update' AS body), true)
      end
    end
  ensure
    connection.execute("SET SESSION sql_mode = '#{previous}'") if previous&.match?(/\A[A-Z0-9_,]*\z/)
  end

  def self.mysql_mode_queries(mode)
    queries = ['SELECT 1 FROM information_schema.tables LIMIT 1']
    if mode.include?('ANSI_QUOTES')
      queries << 'SELECT 1 FROM "information_schema"."tables" LIMIT 1'
      queries << 'SELECT 1 AS $tag$ FROM "information_schema"."tables" AS $tag$ LIMIT 1'
    end
    if mode.include?('NO_BACKSLASH_ESCAPES')
      queries << %q(SELECT 'x\' FROM information_schema.tables WHERE 'a' = 'a' LIMIT 1)
      queries << %q(SELECT 'x\', SLEEP(0), 'tail')
    end
    queries
  end
end
