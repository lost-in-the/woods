# frozen_string_literal: true

require 'spec_helper'
require 'json'

RSpec.describe 'Console response budgets on SQLite', :booted_app do
  let(:table) { 'woods_console_budget_records' }
  let(:wide_cell) { 'fictional-wide-cell-' * 4000 }

  before do
    require 'active_record'
    require 'woods'
    require 'woods/console/server'
    ActiveRecord::Base.establish_connection(adapter: 'sqlite3', database: ':memory:')
    @connection = ActiveRecord::Base.connection
    @connection.create_table(table) do |t|
      t.text :body
      t.timestamps default: -> { 'CURRENT_TIMESTAMP' }
    end
    stub_const('ConsoleBudgetRecord', Class.new(ActiveRecord::Base))
    ConsoleBudgetRecord.table_name = table
    @server = Woods::Console::Server.build_embedded(
      model_validator: Woods::Console::ModelValidator.new(
        registry: { 'ConsoleBudgetRecord' => ConsoleBudgetRecord.column_names },
        table_names: { 'ConsoleBudgetRecord' => table }
      ),
      safe_context: Woods::Console::SafeContext.new(connection: @connection),
      connection: @connection, read_tools_enabled: true, model_tables: { 'ConsoleBudgetRecord' => table }
    )
  end

  after do
    ActiveRecord::Base.connection_pool.disconnect! if defined?(ActiveRecord::Base)
  end

  def dispatch(name, arguments)
    JSON.parse(@server.handle_json(JSON.generate(
                                     jsonrpc: '2.0', id: 1, method: 'tools/call',
                                     params: { name: "console_#{name}", arguments: arguments }
                                   ))).fetch('result')
  end

  def text_of(result)
    result.fetch('content').first.fetch('text')
  end

  it 'omits whole wide cells from the default tools without exposing a prefix' do
    ConsoleBudgetRecord.insert_all!(Array.new(3) { { body: wide_cell } })
    calls = { 'sample' => { limit: 3 }, 'find' => { id: ConsoleBudgetRecord.first.id },
              'pluck' => { columns: ['body'] }, 'recent' => {} }
    calls.each do |name, arguments|
      result = dispatch(name, arguments.merge(model: 'ConsoleBudgetRecord'))
      expect(result.fetch('isError')).to be(false), "#{name}: #{text_of(result)}"
      expect(text_of(result)).to include('value_omitted')
      expect(text_of(result)).not_to include('fictional-wide-cell')
    end
  end

  it 'omits a wide aggregate cell built by the database' do
    ConsoleBudgetRecord.insert_all!(Array.new(2) { { body: 'fictional-short-cell-' * 2000 } })
    result = dispatch('sql', sql: "SELECT group_concat(body) AS combined FROM #{table}")
    expect(result.fetch('isError')).to be(false), text_of(result)
    expect(text_of(result)).to include('value_omitted')
    expect(text_of(result)).not_to include('fictional-short-cell')
  end

  it 'refuses a large collection of ordinary cells with a content-free refusal' do
    ConsoleBudgetRecord.insert_all!(Array.new(1000) { { body: 'ordinary' * 1000 } })
    result = dispatch('sql', sql: "SELECT body FROM #{table}", limit: 1000)
    expect(result.fetch('isError')).to be(true)
    expect(text_of(result)).to start_with('response_budget_exceeded')
    expect(JSON.generate(result)).not_to include('ordinaryordinary')
  end

  it 'returns ordinary rows unchanged' do
    ConsoleBudgetRecord.insert_all!([{ body: 'ordinary fixture' }])
    result = dispatch('sql', sql: "SELECT body FROM #{table}")
    expect(result.fetch('isError')).to be(false)
    expect(text_of(result)).to include('ordinary fixture')
    expect(text_of(result)).not_to include('value_omitted')
  end
end
