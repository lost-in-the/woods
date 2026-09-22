# frozen_string_literal: true

require 'spec_helper'
require 'json'

RSpec.describe 'Console SQLite keyword function policy', :booted_app do
  before do
    require 'active_record'
    require 'woods'
    require 'woods/console/server'
    ActiveRecord::Base.establish_connection(adapter: 'sqlite3', database: ':memory:')
    @connection = ActiveRecord::Base.connection
    @server = Woods::Console::Server.build_embedded(
      model_validator: Woods::Console::ModelValidator.new(registry: {}),
      safe_context: Woods::Console::SafeContext.new(connection: @connection),
      connection: @connection, read_tools_enabled: true
    )
  end

  after do
    ActiveRecord::Base.connection_pool.disconnect! if defined?(ActiveRecord::Base)
  end

  def request(sql)
    JSON.parse(@server.handle_json(JSON.generate(
                                     jsonrpc: '2.0', id: 1, method: 'tools/call',
                                     params: { name: 'console_sql', arguments: { sql: sql } }
                                   ))).fetch('result')
  end

  %w[END WITH ANY SOME BY ASC DESC OFFSET OVER PARTITION FILTER WITHIN EXPLAIN].each do |name|
    it "refuses the callable keyword #{name} before invocation" do
      executed = false
      @connection.raw_connection.create_function(name, 0) do |function|
        executed = true
        function.result = 7
      end
      expect(@connection.select_value("SELECT #{name}()")).to eq(7)
      executed = false
      expect(request("SELECT #{name}() AS value").fetch('isError')).to be(true)
      expect(executed).to be(false)
    end
  end

  [
    'SELECT row_number() OVER () AS value',
    'SELECT sum(1) FILTER (WHERE 1 IN (1, 2)) OVER () AS value',
    'SELECT 1 AS value LIMIT (1) OFFSET (0)',
    'SELECT 1 AS value LIMIT 1 OFFSET (0)',
    'SELECT 1 AS value WHERE EXISTS (SELECT 1) AND (1 IN (1, 2))',
    'SELECT 1 AS value ORDER BY (1)'
  ].each do |sql|
    it "preserves ordinary read grammar: #{sql}" do
      expect(request(sql).fetch('isError')).to be(false)
    end
  end

  [
    'SELECT 1 = ANY()', 'SELECT 1 = SOME()', 'SELECT ALL OFFSET()',
    'SELECT 1 LIMIT 1 + OFFSET()', 'SELECT 1 LIMIT (OFFSET())',
    'SELECT 1 + OVER()', 'SELECT coalesce(FILTER(), 1)'
  ].each do |sql|
    it "refuses nested or operator-position keyword functions: #{sql}" do
      executed = false
      %w[ANY SOME OFFSET OVER FILTER].each do |name|
        @connection.raw_connection.create_function(name, 0) do |function|
          executed = true
          function.result = 1
        end
      end
      @connection.select_value(sql)
      expect(executed).to be(true)
      executed = false
      expect(request(sql).fetch('isError')).to be(true)
      expect(executed).to be(false)
    end
  end
end
