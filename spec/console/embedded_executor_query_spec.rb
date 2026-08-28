# frozen_string_literal: true

require 'spec_helper'
require 'woods'
require 'woods/console/embedded_executor'
require 'woods/console/redactor'

# Focused spec for the console_query / handle_query path with read_tools_enabled.
# Covers: group_by + aggregate select, having, multi-column group_by, order with
# direction, and joins + scope together.

RSpec.describe Woods::Console::EmbeddedExecutor, 'query tool' do
  let(:registry) do
    {
      'Order' => %w[id status amount user_id created_at],
      'LineItem' => %w[id order_id product_id quantity price]
    }
  end
  let(:table_names) { { 'Order' => 'orders', 'LineItem' => 'line_items' } }
  let(:validator) { Woods::Console::ModelValidator.new(registry: registry, table_names: table_names) }
  let(:connection)   { double('Connection') }
  let(:safe_context) { Woods::Console::SafeContext.new(connection: connection) }

  subject(:executor) do
    described_class.new(
      model_validator: validator,
      safe_context: safe_context,
      connection: connection,
      read_tools_enabled: true
    )
  end

  before do
    allow(connection).to receive(:transaction) do |&block|
      block.call
    rescue ActiveRecord::Rollback
      nil
    end
    allow(connection).to receive(:execute)
    allow(connection).to receive(:adapter_name).and_return('PostgreSQL')

    @stubbed_arel_sql = false
    if !defined?(Arel)
      stub_const('Arel', Module.new.tap { |m| m.define_singleton_method(:sql) { |s| s } })
    elsif !Arel.respond_to?(:sql)
      Arel.define_singleton_method(:sql) { |s| s }
      @stubbed_arel_sql = true
    end
  end

  after do
    Arel.singleton_class.send(:remove_method, :sql) if @stubbed_arel_sql
  end

  # Helper: build a chainable relation double that accepts the calls we need.
  def order_relation_double(name = 'order_relation') # rubocop:disable Metrics/AbcSize
    double(name).tap do |rel|
      allow(rel).to receive(:select).and_return(rel)
      allow(rel).to receive(:joins).and_return(rel)
      allow(rel).to receive(:where).and_return(rel)
      allow(rel).to receive(:group).and_return(rel)
      allow(rel).to receive(:having).and_return(rel)
      allow(rel).to receive(:order).and_return(rel)
      allow(rel).to receive(:limit).and_return(rel)
      allow(rel).to receive(:to_sql).and_return('SELECT id FROM orders LIMIT 10000')
    end
  end

  let(:order_model) { class_double('Order') }
  let(:relation)    { order_relation_double }
  let(:query_result) do
    double('ActiveRecord::Result',
           columns: %w[status total],
           rows: [['paid', 500], ['pending', 200]],
           count: 2)
  end

  before do
    stub_const('Order', order_model)
    allow(order_model).to receive(:all).and_return(relation)
    allow(connection).to receive(:select_all).and_return(query_result)
  end

  describe 'group_by + aggregate select' do
    it 'applies group clause and returns grouped rows' do
      response = executor.send_request({
                                         'tool' => 'query',
                                         'params' => {
                                           'model' => 'Order',
                                           'select' => ['status', 'COUNT(*) AS total'],
                                           'group_by' => ['status']
                                         }
                                       })

      expect(response['ok']).to be true
      expect(relation).to have_received(:select).with('status', 'COUNT(*) AS total')
      expect(relation).to have_received(:group).with('status')
      expect(response['result']['rows']).to eq([['paid', 500], ['pending', 200]])
    end
  end

  describe 'having clause' do
    it 'applies a parameterized HAVING condition to a grouped query' do
      response = executor.send_request({
                                         'tool' => 'query',
                                         'params' => {
                                           'model' => 'Order',
                                           'select' => ['status', 'SUM(amount) AS total'],
                                           'group_by' => ['status'],
                                           'having' => ['SUM(amount) > ?', 100]
                                         }
                                       })

      expect(response['ok']).to be true
      expect(relation).to have_received(:group).with('status')
      expect(relation).to have_received(:having).with('SUM(amount) > ?', 100)
    end

    it 'applies a non-empty Hash HAVING condition' do
      response = executor.send_request({
                                         'tool' => 'query',
                                         'params' => {
                                           'model' => 'Order',
                                           'select' => ['status'],
                                           'having' => { 'status' => 'paid' }
                                         }
                                       })

      expect(response['ok']).to be true
      expect(relation).to have_received(:having).with({ 'status' => 'paid' })
    end

    it 'applies a Hash HAVING condition with a qualified column reference' do
      response = executor.send_request({
                                         'tool' => 'query',
                                         'params' => {
                                           'model' => 'Order',
                                           'select' => ['status'],
                                           'having' => { 'orders.amount' => 100 }
                                         }
                                       })

      expect(response['ok']).to be true
      expect(relation).to have_received(:having).with({ 'orders.amount' => 100 })
    end

    it 'rejects a Hash HAVING condition qualified to a real table but a nonexistent column' do
      response = executor.send_request({
                                         'tool' => 'query',
                                         'params' => {
                                           'model' => 'Order',
                                           'select' => ['status'],
                                           'having' => { 'orders.not_a_real_column' => 100 }
                                         }
                                       })

      expect(response['ok']).to be false
      expect(response['error_type']).to eq('validation')
      expect(response['error']).to match(/Unknown column 'not_a_real_column'/)
      expect(connection).not_to have_received(:select_all)
    end

    it 'rejects a Hash HAVING condition with an unsafe column reference' do
      response = executor.send_request({
                                         'tool' => 'query',
                                         'params' => {
                                           'model' => 'Order',
                                           'select' => ['status'],
                                           'having' => { 'bad key' => 2 }
                                         }
                                       })

      expect(response).to include('ok' => false, 'error_type' => 'validation')
      expect(response['error']).to include('Invalid arguments:', 'at `/having`', 'does not match pattern')
      expect(relation).not_to have_received(:having)
    end

    it 'rejects a two-element array whose template is not executable' do
      response = executor.send_request({
                                         'tool' => 'query',
                                         'params' => {
                                           'model' => 'Order',
                                           'select' => ['status'],
                                           'having' => ['not executable', 2]
                                         }
                                       })

      expect(response).to include('ok' => false, 'error_type' => 'validation')
      expect(response['error']).to include('Invalid arguments:', 'at `/having/0`', 'does not match pattern')
      expect(relation).not_to have_received(:having)
    end

    it 'rejects raw-string having clauses (SQL fragment injection vector)' do
      response = executor.send_request({
                                         'tool' => 'query',
                                         'params' => {
                                           'model' => 'Order',
                                           'select' => ['status'],
                                           'group_by' => ['status'],
                                           'having' => '1=1 UNION SELECT password_digest FROM users'
                                         }
                                       })

      expect(response['ok']).to be false
      expect(response['error_type']).to eq('validation')
    end

    it 'rejects arrays with more than one bind value' do
      response = executor.send_request({
                                         'tool' => 'query',
                                         'params' => {
                                           'model' => 'Order',
                                           'select' => ['status'],
                                           'having' => ['SUM(amount) > ?', 100, 200]
                                         }
                                       })

      expect(response).to include('ok' => false, 'error_type' => 'validation')
      expect(response['error']).to include('Invalid arguments:', 'array size at `/having` is greater than: 2')
      expect(relation).not_to have_received(:having)
    end

    it 'rejects a Hash bind value with a typed validation error, not a generic execution failure' do
      response = executor.send_request({
                                         'tool' => 'query',
                                         'params' => {
                                           'model' => 'Order',
                                           'select' => ['status'],
                                           'having' => ['SUM(amount) > ?', { 'sneaky' => 1 }]
                                         }
                                       })

      expect(response).to include('ok' => false, 'error_type' => 'validation')
      expect(relation).not_to have_received(:having)
    end

    it 'rejects an Array bind value with a typed validation error, not a generic execution failure' do
      response = executor.send_request({
                                         'tool' => 'query',
                                         'params' => {
                                           'model' => 'Order',
                                           'select' => ['status'],
                                           'having' => ['SUM(amount) > ?', [1, 2]]
                                         }
                                       })

      expect(response).to include('ok' => false, 'error_type' => 'validation')
      expect(relation).not_to have_received(:having)
    end
  end

  describe 'multi-column group_by' do
    it 'passes all columns to the group clause' do
      response = executor.send_request({
                                         'tool' => 'query',
                                         'params' => {
                                           'model' => 'Order',
                                           'select' => ['status', 'user_id', 'COUNT(*)'],
                                           'group_by' => %w[status user_id]
                                         }
                                       })

      expect(response['ok']).to be true
      expect(relation).to have_received(:group).with('status', 'user_id')
    end
  end

  describe 'order with direction' do
    it 'passes the order hash to the relation' do
      response = executor.send_request({
                                         'tool' => 'query',
                                         'params' => {
                                           'model' => 'Order',
                                           'select' => %w[id created_at],
                                           'order' => { 'created_at' => 'desc' }
                                         }
                                       })

      expect(response['ok']).to be true
      expect(relation).to have_received(:order).with({ 'created_at' => :desc })
    end

    it 'supports ascending order' do
      response = executor.send_request({
                                         'tool' => 'query',
                                         'params' => {
                                           'model' => 'Order',
                                           'select' => ['id'],
                                           'order' => { 'id' => 'asc' }
                                         }
                                       })

      expect(response['ok']).to be true
      expect(relation).to have_received(:order).with({ 'id' => :asc })
    end
  end

  describe 'joins + scope combo' do
    let(:line_item_model) { class_double('LineItem') }

    before do
      stub_const('LineItem', line_item_model)
      allow(order_model).to receive(:reflect_on_association).with(:line_items).and_return(double('line_items'))
      allow(order_model).to receive(:reflect_on_association).with(:user).and_return(double('user'))
    end

    it 'applies joins and where scope together' do
      response = executor.send_request({
                                         'tool' => 'query',
                                         'params' => {
                                           'model' => 'Order',
                                           'select' => %w[id status],
                                           'joins' => ['line_items'],
                                           'scope' => { 'status' => 'paid' }
                                         }
                                       })

      expect(response['ok']).to be true
      expect(relation).to have_received(:joins).with([:line_items])
      expect(relation).to have_received(:where).with({ 'status' => 'paid' })
    end

    it 'supports multiple joins' do
      executor.send_request({
                              'tool' => 'query',
                              'params' => {
                                'model' => 'Order',
                                'select' => ['id'],
                                'joins' => %w[line_items user]
                              }
                            })

      expect(relation).to have_received(:joins).with(%i[line_items user])
    end
  end

  describe 'group_by is skipped when empty' do
    it 'does not call group when group_by is an empty array' do
      executor.send_request({
                              'tool' => 'query',
                              'params' => {
                                'model' => 'Order',
                                'select' => ['id'],
                                'group_by' => []
                              }
                            })

      expect(relation).not_to have_received(:group)
    end
  end

  describe 'joins is skipped when empty' do
    it 'does not call joins when joins array is empty' do
      executor.send_request({
                              'tool' => 'query',
                              'params' => {
                                'model' => 'Order',
                                'select' => ['id'],
                                'joins' => []
                              }
                            })

      expect(relation).not_to have_received(:joins)
    end
  end

  describe 'limit validation' do
    it 'rejects a limit above 10_000 before querying' do
      response = executor.send_request({
                                         'tool' => 'query',
                                         'params' => {
                                           'model' => 'Order',
                                           'select' => ['id'],
                                           'limit' => 99_999
                                         }
                                       })

      expect(response).to include('ok' => false, 'error_type' => 'validation')
      expect(response['error']).to include('Invalid arguments:', 'number at `/limit` is greater than: 10000')
      expect(relation).not_to have_received(:limit)
    end
  end

  describe 'read_tools_enabled: false (default)' do
    subject(:executor_disabled) do
      described_class.new(
        model_validator: validator,
        safe_context: safe_context,
        connection: connection,
        read_tools_enabled: false
      )
    end

    it 'points query at embedded_read_tools and the docs' do
      response = executor_disabled.send_request({
                                                  'tool' => 'query',
                                                  'params' => { 'model' => 'Order', 'select' => ['id'] }
                                                })

      expect(response['ok']).to be false
      expect(response['error_type']).to eq('unsupported')
      expect(response['error']).to include('embedded_read_tools: true')
      expect(response['error']).to include('docs/CONSOLE_MCP_SETUP.md')
    end
  end
end

RSpec.describe Woods::Console::EmbeddedExecutor, 'query tool redaction guards on select aliases' do
  subject(:executor) do
    described_class.new(
      model_validator: validator,
      safe_context: safe_context,
      connection: connection,
      read_tools_enabled: true
    )
  end

  let(:registry) { { 'Order' => %w[id status amount user_id created_at] } }
  let(:table_names) { { 'Order' => 'orders' } }
  let(:validator) { Woods::Console::ModelValidator.new(registry: registry, table_names: table_names) }
  let(:connection) { double('Connection') }
  let(:redacted_columns) { [] }
  let(:redacted_key_values) { [] }
  let(:safe_context) do
    Woods::Console::SafeContext.new(
      connection: connection,
      redacted_columns: redacted_columns,
      redacted_key_values: redacted_key_values
    )
  end

  let(:order_model) { class_double('Order') }
  let(:relation) do
    double('order_relation').tap do |rel|
      allow(rel).to receive(:select).and_return(rel)
      allow(rel).to receive(:where).and_return(rel)
      allow(rel).to receive(:having).and_return(rel)
      allow(rel).to receive(:limit).and_return(rel)
      allow(rel).to receive(:to_sql).and_return('SELECT id FROM orders LIMIT 10000')
    end
  end
  let(:query_result) do
    double('ActiveRecord::Result',
           columns: %w[amount status],
           rows: [%w[s3cret-amount paid]],
           count: 1)
  end

  before do
    stub_const('Order', order_model)
    allow(order_model).to receive(:all).and_return(relation)
    allow(connection).to receive(:transaction) do |&block|
      block.call
    rescue ActiveRecord::Rollback
      nil
    end
    allow(connection).to receive(:execute)
    allow(connection).to receive(:adapter_name).and_return('PostgreSQL')
    allow(connection).to receive(:select_all).and_return(query_result)
  end

  def send_query(select)
    executor.send_request({ 'tool' => 'query', 'params' => { 'model' => 'Order', 'select' => select } })
  end

  context 'when the column is on console_redacted_columns (H2)' do
    let(:redacted_columns) { %w[amount] }

    it 'rejects an alias over a redacted column' do
      response = send_query(['amount AS note'])

      expect(response).to include('ok' => false, 'error_type' => 'validation')
      expect(response['error']).to match(/aliasing redacted column 'amount'/i)
      expect(relation).not_to have_received(:select)
    end

    it 'rejects a qualified alias over a redacted column' do
      response = send_query(['orders.amount AS note'])

      expect(response).to include('ok' => false, 'error_type' => 'validation')
      expect(response['error']).to match(/aliasing redacted column 'amount'/i)
    end

    it 'rejects an aliased aggregate over a redacted column' do
      response = send_query(['SUM(amount) AS total'])

      expect(response).to include('ok' => false, 'error_type' => 'validation')
      expect(response['error']).to match(/aggregating redacted column 'amount'/i)
      expect(relation).not_to have_received(:select)
    end

    it 'rejects a bare aggregate over a redacted column' do
      response = send_query(['SUM(amount)'])

      expect(response).to include('ok' => false, 'error_type' => 'validation')
      expect(response['error']).to match(/aggregating redacted column 'amount'/i)
      expect(relation).not_to have_received(:select)
    end

    it 'keeps direct unaliased selection allowed, with the redactor masking it by header' do
      response = send_query(['amount'])

      expect(response['ok']).to be true
      expect(relation).to have_received(:select).with('amount')

      envelope = { 'columns' => query_result.columns, 'rows' => query_result.rows }
      masked = Woods::Console::Redactor.apply(envelope, safe_context)
      expect(masked['rows']).to eq([['[REDACTED]', 'paid']])
    end
  end

  context 'when the column is on console_redacted_key_values (H2, EAV)' do
    let(:redacted_key_values) do
      [{ 'key_column' => 'status', 'value_column' => 'amount', 'sensitive_keys' => %w[paid] }]
    end

    it 'rejects an alias over the EAV key column' do
      response = send_query(['status AS lookup_key'])

      expect(response).to include('ok' => false, 'error_type' => 'validation')
      expect(response['error']).to match(%r{key/value column 'status'}i)
      expect(relation).not_to have_received(:select)
    end

    it 'rejects an alias over the EAV value column' do
      response = send_query(['amount AS extracted_value'])

      expect(response).to include('ok' => false, 'error_type' => 'validation')
      expect(response['error']).to match(%r{key/value column 'amount'}i)
      expect(relation).not_to have_received(:select)
    end

    it 'rejects an aggregate over the EAV value column scoped to a sensitive key (PR-248 High 1)' do
      response = executor.send_request({
                                         'tool' => 'query',
                                         'params' => {
                                           'model' => 'Order',
                                           'select' => ['MAX(amount) AS leaked'],
                                           'scope' => { 'status' => 'paid' }
                                         }
                                       })

      expect(response).to include('ok' => false, 'error_type' => 'validation')
      expect(response['error']).to match(%r{aggregating redacted key/value column 'amount'}i)
      expect(relation).not_to have_received(:select)
      expect(relation).not_to have_received(:where)
      expect(connection).not_to have_received(:select_all)
    end

    it 'rejects an aggregate over the EAV key column' do
      response = send_query(['COUNT(status) AS keyed'])

      expect(response).to include('ok' => false, 'error_type' => 'validation')
      expect(response['error']).to match(%r{aggregating redacted key/value column 'status'}i)
      expect(relation).not_to have_received(:select)
    end

    it 'keeps direct unaliased EAV selection allowed (the positional redactor still fires)' do
      response = send_query(%w[status amount])

      expect(response['ok']).to be true
      expect(relation).to have_received(:select).with('status', 'amount')

      envelope = { 'columns' => query_result.columns, 'rows' => query_result.rows }
      masked = Woods::Console::Redactor.apply(envelope, safe_context)
      # key cell 'paid' matches sensitive_keys → the value cell (amount) is masked
      expect(masked['rows']).to eq([['[REDACTED]', 'paid']])
    end

    it 'refuses the EAV value column selected without its paired key column (PR-248 round-2 High 1)' do
      response = executor.send_request({
                                         'tool' => 'query',
                                         'params' => {
                                           'model' => 'Order',
                                           'select' => ['amount'],
                                           'scope' => { 'status' => 'paid' }
                                         }
                                       })

      expect(response).to include('ok' => false, 'error_type' => 'validation')
      expect(response['error']).to match(/EAV value column 'amount'/i)
      expect(relation).not_to have_received(:select)
      expect(relation).not_to have_received(:where)
      expect(connection).not_to have_received(:select_all)
    end
  end

  context 'when having references protected columns (PR-248 round-2 High 2)' do
    let(:redacted_key_values) do
      [{ 'key_column' => 'status', 'value_column' => 'amount', 'sensitive_keys' => %w[paid] }]
    end

    it 'refuses an aggregate over the EAV value column in the having template' do
      response = executor.send_request({
                                         'tool' => 'query',
                                         'params' => {
                                           'model' => 'Order',
                                           'select' => ['status'],
                                           'having' => ['MAX(amount) > ?', 100]
                                         }
                                       })

      expect(response).to include('ok' => false, 'error_type' => 'validation')
      expect(response['error']).to match(%r{aggregating redacted key/value column 'amount'}i)
      expect(relation).not_to have_received(:having)
      expect(connection).not_to have_received(:select_all)
    end

    it 'keeps a having predicate on a non-protected column working' do
      response = executor.send_request({
                                         'tool' => 'query',
                                         'params' => {
                                           'model' => 'Order',
                                           'select' => ['status'],
                                           'having' => ['COUNT(*) > ?', 1]
                                         }
                                       })

      expect(response['ok']).to be true
      expect(relation).to have_received(:having).with('COUNT(*) > ?', 1)
    end
  end

  context 'when having aggregates an ordinary redacted column (PR-248 round-2 High 2)' do
    let(:redacted_columns) { %w[amount] }

    it 'refuses an aggregate over the redacted column in the having template' do
      response = executor.send_request({
                                         'tool' => 'query',
                                         'params' => {
                                           'model' => 'Order',
                                           'select' => ['status'],
                                           'having' => ['SUM(amount) > ?', 100]
                                         }
                                       })

      expect(response).to include('ok' => false, 'error_type' => 'validation')
      expect(response['error']).to match(/aggregating redacted column 'amount'/i)
      expect(relation).not_to have_received(:having)
      expect(connection).not_to have_received(:select_all)
    end
  end

  context 'when having carries a bare redacted column predicate (PR-248 round-2 High 2)' do
    let(:redacted_columns) { %w[amount] }

    it 'refuses a bare redacted column predicate in the having template' do
      response = executor.send_request({
                                         'tool' => 'query',
                                         'params' => {
                                           'model' => 'Order',
                                           'select' => ['status'],
                                           'having' => ['amount > ?', 100]
                                         }
                                       })

      expect(response).to include('ok' => false, 'error_type' => 'validation')
      expect(response['error']).to match(/column 'amount' is redacted/i)
      expect(relation).not_to have_received(:having)
      expect(connection).not_to have_received(:select_all)
    end
  end

  context 'when protected predicate columns would act as comparison oracles (PR-248 round 3)' do
    let(:registry) { { 'Order' => %w[id status amount amount_gt user_id created_at] } }
    let(:redacted_columns) { %w[user_id] }
    let(:redacted_key_values) do
      [{ 'key_column' => 'status', 'value_column' => 'amount', 'sensitive_keys' => %w[paid] }]
    end

    it 'refuses an ordinary redacted column used as a Hash HAVING key before building a relation' do
      allow(connection).to receive(:select_all)

      response = executor.send_request({
                                         'tool' => 'query',
                                         'params' => {
                                           'model' => 'Order',
                                           'select' => ['status'],
                                           'having' => { 'user_id' => 100 }
                                         }
                                       })

      expect(response).to include('ok' => false, 'error_type' => 'validation')
      expect(response['error']).to match(/column 'user_id' is redacted/i)
      expect(order_model).not_to have_received(:all)
      expect(relation).not_to have_received(:select)
      expect(relation).not_to have_received(:having)
      expect(relation).not_to have_received(:limit)
      expect(connection).not_to have_received(:select_all)
    end

    it 'refuses an EAV value column used as a Hash HAVING key before building a relation' do
      allow(connection).to receive(:select_all)

      response = executor.send_request({
                                         'tool' => 'query',
                                         'params' => {
                                           'model' => 'Order',
                                           'select' => ['status'],
                                           'having' => { 'amount' => 100 }
                                         }
                                       })

      expect(response).to include('ok' => false, 'error_type' => 'validation')
      expect(response['error']).to match(/EAV value column 'amount'/i)
      expect(order_model).not_to have_received(:all)
      expect(relation).not_to have_received(:select)
      expect(relation).not_to have_received(:having)
      expect(relation).not_to have_received(:limit)
      expect(connection).not_to have_received(:select_all)
    end

    it 'keeps a real Hash HAVING column ending in a scope suffix allowed' do
      response = executor.send_request({
                                         'tool' => 'query',
                                         'params' => {
                                           'model' => 'Order',
                                           'select' => ['status'],
                                           'having' => { 'amount_gt' => 100 }
                                         }
                                       })

      expect(response['ok']).to be true
      expect(relation).to have_received(:having).with({ 'amount_gt' => 100 })
      expect(connection).to have_received(:select_all)
    end

    it 'refuses an EAV value column used as a bare array HAVING predicate before building a relation' do
      allow(connection).to receive(:select_all)

      response = executor.send_request({
                                         'tool' => 'query',
                                         'params' => {
                                           'model' => 'Order',
                                           'select' => ['status'],
                                           'having' => ['amount > ?', 100]
                                         }
                                       })

      expect(response).to include('ok' => false, 'error_type' => 'validation')
      expect(response['error']).to match(/EAV value column 'amount'/i)
      expect(order_model).not_to have_received(:all)
      expect(relation).not_to have_received(:select)
      expect(relation).not_to have_received(:having)
      expect(relation).not_to have_received(:limit)
      expect(connection).not_to have_received(:select_all)
    end

    it 'refuses an ordinary redacted column used as an array scope before building a relation' do
      allow(connection).to receive(:select_all)

      response = executor.send_request({
                                         'tool' => 'query',
                                         'params' => {
                                           'model' => 'Order',
                                           'select' => ['status'],
                                           'scope' => ['user_id > ?', 100]
                                         }
                                       })

      expect(response).to include('ok' => false, 'error_type' => 'validation')
      expect(response['error']).to match(/column 'user_id' is redacted/i)
      expect(order_model).not_to have_received(:all)
      expect(relation).not_to have_received(:select)
      expect(relation).not_to have_received(:where)
      expect(relation).not_to have_received(:limit)
      expect(connection).not_to have_received(:select_all)
    end

    it 'keeps a real array scope column ending in a scope suffix allowed' do
      response = executor.send_request({
                                         'tool' => 'query',
                                         'params' => {
                                           'model' => 'Order',
                                           'select' => ['status'],
                                           'scope' => ['amount_gt > ?', 100]
                                         }
                                       })

      expect(response['ok']).to be true
      expect(relation).to have_received(:where).with('amount_gt > ?', 100)
      expect(connection).to have_received(:select_all)
    end

    it 'refuses an EAV value column used as a suffixed Hash scope key before building a relation' do
      allow(connection).to receive(:select_all)

      response = executor.send_request({
                                         'tool' => 'query',
                                         'params' => {
                                           'model' => 'Order',
                                           'select' => ['status'],
                                           'scope' => { 'amount_gt' => 100 }
                                         }
                                       })

      expect(response).to include('ok' => false, 'error_type' => 'validation')
      expect(response['error']).to match(/EAV value column 'amount'/i)
      expect(order_model).not_to have_received(:all)
      expect(relation).not_to have_received(:select)
      expect(relation).not_to have_received(:where)
      expect(relation).not_to have_received(:limit)
      expect(connection).not_to have_received(:select_all)
    end

    it 'refuses an EAV value column used as an array scope before building a relation' do
      allow(connection).to receive(:select_all)

      response = executor.send_request({
                                         'tool' => 'query',
                                         'params' => {
                                           'model' => 'Order',
                                           'select' => ['status'],
                                           'scope' => ['amount > ?', 100]
                                         }
                                       })

      expect(response).to include('ok' => false, 'error_type' => 'validation')
      expect(response['error']).to match(/EAV value column 'amount'/i)
      expect(order_model).not_to have_received(:all)
      expect(relation).not_to have_received(:select)
      expect(relation).not_to have_received(:where)
      expect(relation).not_to have_received(:limit)
      expect(connection).not_to have_received(:select_all)
    end

    it 'keeps EAV key predicates allowed' do
      response = executor.send_request({
                                         'tool' => 'query',
                                         'params' => {
                                           'model' => 'Order',
                                           'select' => %w[status amount],
                                           'scope' => { 'status' => 'paid' },
                                           'having' => { 'status' => 'paid' }
                                         }
                                       })

      expect(response['ok']).to be true
      expect(relation).to have_received(:where).with({ 'status' => 'paid' })
      expect(relation).to have_received(:having).with({ 'status' => 'paid' })
      expect(connection).to have_received(:select_all)
    end
  end
end
