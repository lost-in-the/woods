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
    queries.each do |sql, permitted|
      result = executor.send_request('tool' => 'sql', 'params' => { 'sql' => sql })
      raise "Console contract failed for #{sql}: #{result.inspect}" unless result['ok'] == permitted
    end
    :passed
  end
end
