# frozen_string_literal: true

require 'spec_helper'
require 'json'

RSpec.describe 'Console SQLite read policy', :booted_app do
  before do
    require 'active_record'
    require 'woods'
    require 'woods/console/server'
    ActiveRecord::Base.establish_connection(adapter: 'sqlite3', database: ':memory:')
    @connection = ActiveRecord::Base.connection
    @connection.create_table(:policy_blocked) { |table| table.string :message }
    @connection.create_table(:policy_allowed) { |table| table.string :message }
    @connection.execute("INSERT INTO policy_blocked (message) VALUES ('blocked fixture')")
    @connection.execute("INSERT INTO policy_allowed (message) VALUES ('allowed fixture')")
    @previous_blocked = Woods.configuration.console_blocked_tables
    Woods.configuration.console_blocked_tables = ['policy_blocked']
    @server = Woods::Console::Server.build_embedded(
      model_validator: Woods::Console::ModelValidator.new(registry: {}),
      safe_context: Woods::Console::SafeContext.new(connection: @connection),
      connection: @connection, read_tools_enabled: true
    )
  end

  after do
    Woods.configuration.console_blocked_tables = @previous_blocked if defined?(@previous_blocked)
    ActiveRecord::Base.connection_pool.disconnect! if defined?(ActiveRecord::Base)
  end

  def request(sql)
    JSON.parse(@server.handle_json(JSON.generate(
                                     jsonrpc: '2.0', id: 1, method: 'tools/call',
                                     params: { name: 'console_sql', arguments: { sql: sql } }
                                   ))).fetch('result')
  end

  ['policy_blocked', '"policy_blocked"', '`policy_blocked`', '[policy_blocked]',
   "'policy_blocked'", '(policy_blocked)', "main.'policy_blocked'",
   'policy_allowed, (policy_blocked)',
   'policy_allowed JOIN (policy_blocked) ON 1 = 1'].each do |factor|
    it "refuses blocked rows through #{factor}" do
      result = request("SELECT * FROM #{factor}")
      expect(result.fetch('isError')).to be(true)
      expect(result.to_json).not_to include('blocked fixture')
    end
  end

  ['SELECT * FROM"policy_blocked"', "SELECT * FROM'policy_blocked'",
   'SELECT * FROM(policy_blocked)',
   'SELECT * FROM policy_allowed JOIN"policy_blocked" ON 1=1',
   'SELECT b.message FROM (SELECT 1) AS a, policy_blocked AS b',
   'SELECT b.message FROM policy_allowed a JOIN (SELECT 1) AS x, policy_blocked b',
   'SELECT c.message FROM policy_allowed a JOIN policy_allowed b ON (1=1), policy_blocked c',
   'SELECT b.message FROM policy_allowed AS "WHERE", policy_blocked b',
   'SELECT b.message FROM policy_allowed AS OFFSET, policy_blocked b',
   'SELECT b.message FROM policy_allowed WINDOW, policy_blocked b'].each do |sql|
    it "refuses unseparated table syntax: #{sql}" do
      result = request(sql)
      expect(result.fetch('isError')).to be(true)
      expect(result.to_json).not_to include('blocked fixture')
    end
  end

  ['policy_allowed', '"policy_allowed"', '`policy_allowed`',
   '(SELECT message FROM policy_allowed) AS selected'].each do |factor|
    it "allows ordinary reads through #{factor}" do
      result = request("SELECT * FROM #{factor}")
      expect(result.fetch('isError')).to be(false)
      expect(result.to_json).to include('allowed fixture')
    end
  end

  ['é', 'audit$count', 'écount', "'audit_effect'", '[audit_effect]', '`audit_effect`', '"audit_effect"'].each do |name|
    it "refuses a non-allowlisted quoted function #{name} before execution" do
      executed = false
      function = name.match?(/audit_effect/) ? 'audit_effect' : name
      @connection.raw_connection.create_function(function, 0) { executed = true }
      expect(request("SELECT #{name}() AS value").fetch('isError')).to be(true)
      expect(executed).to be(false)
    end
  end
end
