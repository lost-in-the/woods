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
end
