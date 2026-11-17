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

  {
    'WOODS_PG_URL' => ->(connection) { connection.select_value('SHOW statement_timeout') },
    'WOODS_MYSQL_URL' => ->(connection) { connection.select_value('SELECT @@SESSION.max_execution_time').to_i }
  }.each do |variable, read_timeout|
    context "with a host transaction on #{variable}" do
      before do
        require 'active_record'
        require 'woods'
        ActiveRecord::Base.establish_connection(ENV.fetch(variable))
      end

      after { ActiveRecord::Base.connection_pool.disconnect! }

      let(:connection) { ActiveRecord::Base.connection }

      it_behaves_like 'a Console transaction inside a host transaction'
      it_behaves_like 'a Console statement timeout inside a host transaction', read_timeout
    end
  end

  context 'with a host transaction that set its own PostgreSQL statement timeout' do
    before do
      require 'active_record'
      require 'woods'
      require 'woods/console/safe_context'
      ActiveRecord::Base.establish_connection(ENV.fetch('WOODS_PG_URL'))
      connection.create_table(:woods_console_tx_probe, force: true) { |table| table.string :label }
    end

    after do
      connection.drop_table(:woods_console_tx_probe, if_exists: true)
      ActiveRecord::Base.connection_pool.disconnect!
    end

    let(:connection) { ActiveRecord::Base.connection }

    it 'keeps the host value after the Console block' do
      context = Woods::Console::SafeContext.new(connection: connection, timeout_ms: 4321)
      connection.transaction do
        connection.execute("SET LOCAL statement_timeout = '9s'")
        expect(context.execute { connection.select_value('SHOW statement_timeout') }).to eq('4321ms')
        expect(connection.select_value('SHOW statement_timeout')).to eq('9s')
      end
    end

    it 'cancels a statement past the Console timeout and the host transaction still commits' do
      context = Woods::Console::SafeContext.new(connection: connection, timeout_ms: 50)
      connection.transaction do
        connection.execute("INSERT INTO woods_console_tx_probe (label) VALUES ('host before')")
        expect { context.execute { connection.select_value('SELECT pg_sleep(2)') } }
          .to raise_error(ActiveRecord::QueryCanceled)
        connection.execute("INSERT INTO woods_console_tx_probe (label) VALUES ('host after')")
      end
      expect(connection.select_values('SELECT label FROM woods_console_tx_probe').sort)
        .to eq(['host after', 'host before'])
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

  # PostgreSQL keeps repeated names through the row cap, so the refusal is
  # the redactor's header-identity rule, not a database error.
  it 'refuses a protected column repeated through the row cap on PostgreSQL' do
    with_policy_server('WOODS_PG_URL') do |server|
      users = WoodsConsoleOutputPolicyContract::TABLES[0]
      result = WoodsConsoleOutputPolicyContract.assert_request!(
        server, 'console_sql', { sql: "SELECT a.secret, a.secret FROM #{users} a" }, refused: true
      )
      expect(result.to_json).to include('protected column more than once')
    end
  end

  it 'masks a single protected column beside a repeated ordinary column on PostgreSQL' do
    with_policy_server('WOODS_PG_URL') do |server|
      users = WoodsConsoleOutputPolicyContract::TABLES[0]
      result = WoodsConsoleOutputPolicyContract.assert_request!(
        server, 'console_sql', { sql: "SELECT a.secret, a.name, a.name FROM #{users} a" }
      )
      payload = JSON.parse(result.fetch('content').first.fetch('text'))
      expect(payload.fetch('columns')).to eq(%w[secret name name])
      expect(payload.fetch('rows')).to contain_exactly(%w[[REDACTED] ordinary ordinary], %w[[REDACTED] second second])
    end
  end
end
