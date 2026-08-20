# frozen_string_literal: true

require 'spec_helper'
require 'woods/console/embedded_executor'

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
  let(:validator)    { Woods::Console::ModelValidator.new(registry: registry) }
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
      expect(response['error']).to include('Rejected column reference')
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
      expect(response['error']).to include('having: unsupported SQL template')
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
      expect(response['error']).to include('having must contain exactly one template and one bind value')
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
      expect(response['error']).to include('limit must be between 1 and 10000')
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
