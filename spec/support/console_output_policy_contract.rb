# frozen_string_literal: true

# Synthetic, connection-local tables only. Also runnable with an installed
# adapter outside the development bundle (for example Rails' Trilogy adapter).
module WoodsConsoleOutputPolicyContract # rubocop:disable Metrics/ModuleLength
  TABLES = %w[woods_policy_users woods_policy_preferences woods_policy_blocked].freeze
  SECRET = 'synthetic protected fixture'
  BLOCKED = 'synthetic blocked fixture'
  EAV = [{ key_column: 'name', value_column: 'value', sensitive_keys: ['private'] }].freeze

  def self.verify!(connection)
    require 'woods'
    require 'woods/console/server'
    previous = Woods.configuration
    create_fixture!(connection)
    server = build_server(connection)
    verify_common!(server)
    dialect = Woods::Console::AdapterFamily.for(connection)
    verify_postgres!(connection, server) if dialect == :postgres
    verify_mysql!(connection, server) if dialect == :mysql
    :passed
  ensure
    Woods.configuration = previous if previous
    TABLES.each { |table| connection.drop_table(table, if_exists: true) }
    %i[User Preference].each { |name| remove_const(name) if const_defined?(name, false) }
  end

  def self.create_fixture!(connection)
    connection.create_table(TABLES[0], temporary: true) do |table|
      table.string :name
      table.string :secret
    end
    connection.create_table(TABLES[1], temporary: true) do |table|
      table.string :name
      table.string :value
      table.integer :user_id
    end
    connection.create_table(TABLES[2], temporary: true) { |table| table.string :message }
    connection.execute("INSERT INTO #{TABLES[0]} (name, secret) " \
                       "VALUES ('ordinary', '#{SECRET}'), ('second', '#{SECRET}')")
    connection.execute("INSERT INTO #{TABLES[1]} (name, value, user_id) VALUES ('private', '#{SECRET}', 1)")
    connection.execute("INSERT INTO #{TABLES[2]} (message) VALUES ('#{BLOCKED}')")
    define_models!
  end

  def self.define_models!
    const_set(:User, Class.new(ActiveRecord::Base) { self.table_name = TABLES[0] })
    const_set(:Preference, Class.new(ActiveRecord::Base) do
      self.table_name = TABLES[1]
      belongs_to :user, class_name: 'WoodsConsoleOutputPolicyContract::User'
    end)
  end

  def self.build_server(connection)
    Woods.configuration = Woods::Configuration.new
    Woods.configuration.console_blocked_tables = [TABLES[2]]
    Woods.configuration.context_format = :json
    models = [User, Preference]
    tables = models.to_h { |model| [model.name, model.table_name] }
    Woods::Console::Server.build_embedded(
      model_validator: Woods::Console::ModelValidator.new(
        registry: models.to_h { |model| [model.name, model.column_names] }, table_names: tables
      ), connection: connection, safe_context: Woods::Console::SafeContext.new(connection: connection),
      redacted_columns: ['secret'], redacted_key_values: EAV, read_tools_enabled: true,
      model_tables: tables, model_reflections: { Preference.name => { 'user' => TABLES[0] } }
    )
  end

  def self.verify_common!(server)
    verify_limits!(server)
    verify_eav!(server)
    result = assert_request!(server, 'console_sql', { sql: "SELECT secret FROM #{TABLES[0]}", limit: 1 })
    raise 'Protected scalar was not masked' unless result.to_json.include?('[REDACTED]')

    assert_request!(server, 'console_sample', { model: User.name, columns: %w[id name secret], limit: 1 })
    assert_request!(server, 'console_recent', { model: Preference.name, order_by: 'name' })
    assert_request!(server, 'console_recent', { model: Preference.name, order_by: 'value' }, refused: true)
  end

  def self.verify_limits!(server)
    result = assert_request!(server, 'console_sql', { sql: "SELECT id FROM #{TABLES[0]} -- note", limit: 1 })
    raise 'Limit changed the result' unless JSON.parse(result.fetch('content').first.fetch('text')).fetch('count') == 1

    sql = "SELECT 1 FROM #{TABLES[0]}) AS x, #{TABLES[2]} --"
    assert_request!(server, 'console_sql', { sql: sql, limit: 1 }, refused: true)
  end

  def self.verify_eav!(server)
    query = { model: Preference.name, joins: ['user'], select: ["#{TABLES[1]}.name", "#{TABLES[1]}.value"] }
    result = assert_request!(server, 'console_query', query)
    raise 'Joined EAV value was not masked' unless result.to_json.include?('[REDACTED]')

    spoof = query.merge(select: ["#{TABLES[0]}.name", "#{TABLES[1]}.value"])
    assert_request!(server, 'console_query', spoof, refused: true)
    sql = "SELECT a.name, b.value FROM #{TABLES[1]} a JOIN #{TABLES[1]} b ON a.id = b.id"
    assert_request!(server, 'console_sql', { sql: sql }, refused: true)
    assert_request!(server, 'console_sql', { sql: "SELECT name, value FROM #{TABLES[1]}", limit: 1 })
  end

  def self.verify_postgres!(connection, server)
    nested = "SELECT message /* outer /* inner */ ' */ FROM #{TABLES[2]} WHERE 'a'='a' -- '"
    raise 'Nested-comment fixture did not read its table' unless connection.select_value(nested) == BLOCKED

    assert_request!(server, 'console_sql', { sql: nested }, refused: true)
    ["SELECT u FROM #{TABLES[0]} u", "SELECT ARRAY[u] AS result FROM #{TABLES[0]} u",
     "SELECT array_agg(u.*) FROM #{TABLES[0]} u",
     "SELECT u FROM #{TABLES[0]}* u", "SELECT u FROM #{TABLES[0]}\"u\"",
     "SELECT derived FROM (SELECT * FROM #{TABLES[0]}) AS derived"].each do |sql|
      unless connection.select_all(sql).to_json.include?(SECRET)
        raise 'Composite fixture did not contain protected value'
      end

      assert_request!(server, 'console_sql', { sql: sql }, refused: true)
    end
    assert_request!(server, 'console_sql', { sql: "SELECT u.id FROM #{TABLES[0]} u" })
    verify_postgres_types!(server)
  end

  def self.verify_postgres_types!(server)
    assert_request!(server, 'console_sql', { sql: "SELECT 1 AS id, 'ordinary' AS label" })
    assert_request!(server, 'console_sql', { sql: "SELECT ARRAY[1,2] AS ids, ARRAY['a','b'] AS labels" })
    assert_request!(server, 'console_sql', { sql: "SELECT '0/16B6C50'::pg_lsn AS opaque" }, refused: true)
    # Compact valid PostgreSQL syntax intentionally misses the preliminary
    # projection scan: actual result metadata must still prevent disclosure.
    sql = "SELECT\"u\" FROM #{TABLES[0]}\"u\""
    assert_request!(server, 'console_sql', { sql: sql }, refused: true)
  end

  def self.verify_mysql!(connection, server)
    sql = "SELECT * /*!99999 ' */ FROM #{TABLES[2]} WHERE 'a'='a' -- '"
    raise 'Guarded-comment fixture did not read its table' unless connection.select_all(sql).to_json.include?(BLOCKED)

    assert_request!(server, 'console_sql', { sql: sql }, refused: true)
    assert_request!(server, 'console_sql', { sql: 'SELECT /*! 1 + */ 1 AS total' })
    mode = connection.select_value('SELECT @@SESSION.sql_mode')
    literal = mode.include?('NO_BACKSLASH_ESCAPES') ? %q('a\') : %q('a\'b')
    alias_sql = "SELECT #{literal} AS note, secret AS visible FROM #{TABLES[0]} WHERE name = 'ordinary'"
    assert_request!(server, 'console_sql', { sql: alias_sql }, refused: true)
    previous = connection.select_value('SELECT @@SESSION.max_execution_time')
    assert_request!(server, 'console_sample', { model: User.name, columns: ['id'], limit: 1 })
    restored = connection.select_value('SELECT @@SESSION.max_execution_time')
    raise 'MySQL timeout leaked across the request' unless restored == previous
  end

  def self.assert_request!(server, tool, arguments, refused: false)
    result = JSON.parse(server.handle_json(JSON.generate(
                                             jsonrpc: '2.0', id: 1, method: 'tools/call',
                                             params: { name: tool, arguments: arguments }
                                           ))).fetch('result')
    text = result.to_json
    raise "Unexpected policy result: #{result.inspect}" unless result.fetch('isError') == refused
    raise 'Refusal was not a typed policy error' if refused && !text.include?('Rejected:')
    raise 'Protected fixture escaped policy' if text.include?(SECRET) || text.include?(BLOCKED)

    result
  end
end
