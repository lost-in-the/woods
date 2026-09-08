# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Console SQL against real database dialects', :live_backends do
  %w[WOODS_PG_URL WOODS_MYSQL_URL].each do |variable|
    it "enforces blocked-table boundaries using #{variable}" do
      require 'active_record'
      ActiveRecord::Base.establish_connection(ENV.fetch(variable))
      expect(WoodsConsoleDialectContract.verify!(ActiveRecord::Base.connection)).to eq(:passed)
    ensure
      ActiveRecord::Base.connection_pool.disconnect! if defined?(ActiveRecord::Base)
    end
  end
end
