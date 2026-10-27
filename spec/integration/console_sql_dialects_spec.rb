# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Console SQL against real database dialects', :live_backends do
  %w[WOODS_PG_URL WOODS_MYSQL_URL].each do |variable|
    it "enforces blocked-table boundaries using #{variable}" do
      require 'active_record'
      ActiveRecord::Base.establish_connection(ENV.fetch(variable))
      expect(WoodsConsoleDialectContract.verify!(ActiveRecord::Base.connection)).to eq(:passed)
      expect(WoodsConsoleOutputPolicyContract.verify!(ActiveRecord::Base.connection)).to eq(:passed)
    ensure
      ActiveRecord::Base.connection_pool.disconnect! if defined?(ActiveRecord::Base)
    end
  end

  it 'refuses PostgreSQL column alias lists through the redaction identity policy' do
    require 'active_record'
    require 'woods'
    require 'woods/console/server'
    ActiveRecord::Base.establish_connection(ENV.fetch('WOODS_PG_URL'))
    connection = ActiveRecord::Base.connection
    previous = Woods.configuration
    WoodsConsoleOutputPolicyContract.create_fixture!(connection)
    server = WoodsConsoleOutputPolicyContract.build_server(connection, redacted_key_values: [])
    expect { WoodsConsoleOutputPolicyContract.verify_column_alias_lists!(server) }.not_to raise_error
  ensure
    Woods.configuration = previous if previous
    if connection
      WoodsConsoleOutputPolicyContract::TABLES.each { |table| connection.drop_table(table, if_exists: true) }
      %i[User Preference].each { |name| WoodsConsoleOutputPolicyContract.send(:remove_const, name) }
    end
    ActiveRecord::Base.connection_pool.disconnect! if defined?(ActiveRecord::Base)
  end

  # One policy server over the shared fixture for the dialect named by
  # +variable+, torn down with the connection.
  def with_policy_server(variable)
    require 'active_record'
    require 'woods'
    require 'woods/console/server'
    ActiveRecord::Base.establish_connection(ENV.fetch(variable))
    connection = ActiveRecord::Base.connection
    previous = Woods.configuration
    WoodsConsoleOutputPolicyContract.create_fixture!(connection)
    yield WoodsConsoleOutputPolicyContract.build_server(connection, redacted_key_values: [])
  ensure
    Woods.configuration = previous if previous
    if connection
      WoodsConsoleOutputPolicyContract::TABLES.each { |table| connection.drop_table(table, if_exists: true) }
      %i[User Preference].each { |name| WoodsConsoleOutputPolicyContract.send(:remove_const, name) }
    end
    ActiveRecord::Base.connection_pool.disconnect! if defined?(ActiveRecord::Base)
  end

  # The row cap wraps every statement in a derived table. MySQL and MariaDB
  # require unique column names there; PostgreSQL returns repeated names as
  # the inner statement produced them. The join is between the two fixture
  # tables (both carry `id` and `name`), not a self-join: the fixture tables
  # are temporary, and MySQL cannot reopen a temporary table within one
  # statement, which would fail earlier for an unrelated reason.
  it 'refuses repeated output names on MySQL with a message naming the row-cap cause' do
    with_policy_server('WOODS_MYSQL_URL') do |server|
      users, preferences = WoodsConsoleOutputPolicyContract::TABLES
      result = WoodsConsoleOutputPolicyContract.assert_request!(
        server, 'console_sql',
        { sql: "SELECT * FROM #{users} u JOIN #{preferences} p ON p.user_id = u.id" }, refused: true
      )
      expect(result.to_json).to include('unique output column names')
    end
  end

  it 'masks every copy of a protected column repeated through the row cap on PostgreSQL' do
    with_policy_server('WOODS_PG_URL') do |server|
      users = WoodsConsoleOutputPolicyContract::TABLES[0]
      result = WoodsConsoleOutputPolicyContract.assert_request!(
        server, 'console_sql', { sql: "SELECT a.secret, a.secret FROM #{users} a" }
      )
      payload = JSON.parse(result.fetch('content').first.fetch('text'))
      expect(payload.fetch('columns')).to eq(%w[secret secret])
      expect(payload.fetch('rows')).to all(eq(['[REDACTED]', '[REDACTED]']))
    end
  end
end
