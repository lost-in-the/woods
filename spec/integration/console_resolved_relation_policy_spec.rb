# frozen_string_literal: true

require 'spec_helper'
require 'json'

RSpec.describe 'Console resolved relation table policy', :booted_app do
  before do
    require 'active_record'
    require 'woods'
    require 'woods/console/server'
    ActiveRecord::Base.establish_connection(adapter: 'sqlite3', database: ':memory:')
    @connection = ActiveRecord::Base.connection
    %i[scope_allowed scope_blocked].each do |name|
      @connection.create_table(name) { |table| table.string :message }
    end
    @connection.create_table(:scope_children) { |table| table.integer :parent_id }
    @connection.execute("INSERT INTO scope_allowed (message) VALUES ('ordinary row')")
    @connection.execute("INSERT INTO scope_blocked (message) VALUES ('restricted row'), ('second restricted row')")
    @connection.execute('INSERT INTO scope_children (parent_id) VALUES (1)')
    @scope_calls = 0
    @callbacks = [0]
    scope_builder = lambda {
      @scope_calls += 1
      @scope_table
    }
    callbacks = @callbacks
    callback = -> { callbacks[0] += 1 }
    stub_const('ScopeAllowed', Class.new(ActiveRecord::Base) do
      self.table_name = 'scope_allowed'
      has_many :children, class_name: 'ScopeChild', foreign_key: :parent_id
      default_scope { from("#{scope_builder.call} AS scope_allowed") }
      after_find(&callback)
    end)
    stub_const('ScopeChild', Class.new(ActiveRecord::Base) { self.table_name = 'scope_children' })
    @scope_table = 'scope_blocked'
    @original_config = Woods.configuration
    Woods.configuration = Woods::Configuration.new
    Woods.configuration.console_blocked_tables = ['scope_blocked']
    Woods.configuration.context_format = :json
    models = [ScopeAllowed, ScopeChild]
    tables = models.to_h { |model| [model.name, model.table_name] }
    @server = Woods::Console::Server.build_embedded(
      model_validator: Woods::Console::ModelValidator.new(
        registry: models.to_h { |model| [model.name, model.column_names] }, table_names: tables
      ),
      safe_context: Woods::Console::SafeContext.new(connection: @connection), connection: @connection,
      model_tables: tables, model_reflections: { 'ScopeAllowed' => { 'children' => 'scope_children' } }
    )
  end

  after do
    Woods.configuration = @original_config if @original_config
    ActiveRecord::Base.connection_pool.disconnect! if defined?(ActiveRecord::Base)
  end

  def request(tool, arguments)
    @statements = []
    subscriber = ActiveSupport::Notifications.subscribe('sql.active_record') do |*event|
      @statements << event.last[:sql]
    end
    JSON.parse(@server.handle_json(JSON.generate(
                                     jsonrpc: '2.0', id: 1, method: 'tools/call',
                                     params: { name: tool, arguments: { model: 'ScopeAllowed' }.merge(arguments) }
                                   ))).fetch('result')
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end

  cases = {
    'console_count' => [{}, { 'count' => 1 }],
    'console_aggregate' => [{ function: 'sum', column: 'id' }, { 'value' => 1 }],
    'console_sample' => [{}, { 'records' => [{ 'id' => 1, 'message' => 'ordinary row' }] }],
    'console_recent' => [{ order_by: 'id' }, { 'records' => [{ 'id' => 1, 'message' => 'ordinary row' }] }],
    'console_find' => [{ id: 1 }, { 'record' => { 'id' => 1, 'message' => 'ordinary row' } }],
    'console_pluck' => [{ columns: ['message'] }, { 'columns' => ['message'], 'values' => ['ordinary row'] }],
    'console_association_count' => [{ id: 1, association: 'children' }, { 'count' => 1 }]
  }

  cases.each do |tool, (arguments, expected)|
    it "refuses #{tool} before reading a blocked default-scope table or instantiating its records" do
      result = request(tool, arguments)
      expect(result.fetch('isError')).to be(true)
      expect(result.to_json).to include('console_blocked_tables')
      expect(@statements.grep(/\b(?:FROM|JOIN)\s+scope_blocked/i)).to be_empty
      expect(@callbacks).to eq([0])
    end

    it "preserves #{tool} results and resolves its allowed default scope only once" do
      @scope_table = 'scope_allowed'
      result = request(tool, arguments)
      expect(result.fetch('isError')).to be(false)
      expect(JSON.parse(result.fetch('content').first.fetch('text'))).to eq(expected)
      expect(@scope_calls).to eq(1)
    end
  end

  it 'also gates find-by locators before fetching a blocked record' do
    result = request('console_find', by: { message: 'restricted row' })
    expect(result.fetch('isError')).to be(true)
    expect(@statements.grep(/\b(?:FROM|JOIN)\s+scope_blocked/i)).to be_empty
    expect(@callbacks).to eq([0])
  end

  it 'retains the final association target scope check' do
    @scope_table = 'scope_allowed'
    # A late default-scope change on a reused fixture constant is cached on Rails 6.
    # Declare the association scope explicitly and verify the SQL before testing the gate.
    ScopeAllowed.has_many :children, -> { from('scope_blocked AS scope_children') },
                          class_name: 'ScopeChild', foreign_key: :parent_id
    expect(ScopeAllowed.new(id: 1).children.all.to_sql).to include('FROM scope_blocked AS scope_children')
    result = request('console_association_count', id: 1, association: 'children')
    expect(result.fetch('isError')).to be(true)
    expect(@statements.grep(/\b(?:FROM|JOIN)\s+scope_blocked/i)).to be_empty
    expect(@callbacks).to eq([1])
  end
end
