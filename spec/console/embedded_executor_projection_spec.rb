# frozen_string_literal: true

require 'spec_helper'
require 'woods'
require 'woods/console/embedded_executor'

RSpec.describe Woods::Console::EmbeddedExecutor, 'projection source types' do
  let(:registry) { { 'Order' => ['id'], 'LineItem' => ['quantity'] } }
  let(:validator) do
    Woods::Console::ModelValidator.new(registry: registry,
                                       table_names: { 'Order' => 'orders', 'LineItem' => 'line_items' })
  end
  let(:connection) { double('connection', adapter_name: 'PostgreSQL', execute: nil) }
  let(:safe_context) do
    Woods::Console::SafeContext.new(
      connection: connection,
      redacted_key_values: [{ 'key_column' => 'quantity', 'value_column' => 'price', 'sensitive_keys' => ['2'] }]
    )
  end
  let(:quantity_type) { double('quantity type') }
  let(:item_model) { double('LineItem', table_name: 'line_items', type_for_attribute: quantity_type) }
  let(:relation) { double('relation', to_sql: 'SELECT orders.id, line_items.quantity FROM orders') }

  subject(:executor) do
    described_class.new(model_validator: validator, safe_context: safe_context,
                        connection: connection, read_tools_enabled: true)
  end

  before do
    stub_const('Order', double('Order', all: relation))
    stub_const('LineItem', item_model)
    allow(relation).to receive(:select).and_return(relation)
    allow(relation).to receive(:limit).and_return(relation)
    allow(connection).to receive(:select_all).and_return(double('result', columns: %w[id quantity], rows: []))
    allow(connection).to receive(:transaction) do |&block|
      block.call
    rescue ActiveRecord::Rollback
      nil
    end
    allow(safe_context).to receive(:with_key_value_types).and_call_original
  end

  [
    ['orders.id', 'line_items.quantity'],
    [' orders.id ', ' line_items.quantity ']
  ].each do |projection|
    it "uses the executed projection's source type for #{projection.inspect}" do
      request = { 'tool' => 'query', 'params' => { 'model' => 'Order', 'select' => projection } }
      original = Marshal.load(Marshal.dump(request))

      response = executor.send_request(request)

      expect(response).to include('ok' => true)
      expect(relation).to have_received(:select).with('orders.id', 'line_items.quantity').once
      expect(safe_context).to have_received(:with_key_value_types).with({ 'quantity' => [quantity_type] }, raw: true)
      expect(request).to eq(original)
    end
  end

  it 'keeps comma-combined expressions outside the modern schema' do
    response = executor.send_request('tool' => 'query', 'params' => {
                                       'model' => 'Order', 'select' => ['orders.id, line_items.quantity']
                                     })

    expect(response).to include('ok' => false, 'error_type' => 'validation')
    expect(relation).not_to have_received(:select)
    expect(connection).not_to have_received(:select_all)
  end

  [
    ['LINE_ITEMS', 'line_items'],
    ['Line_Items', 'line_items'],
    ['public.LINE_ITEMS', 'line_items'],
    ['LINE_ITEMS', 'public.line_items'],
    ['other.LINE_ITEMS', 'public.line_items']
  ].each do |source, table_name|
    it "attaches types conservatively for #{source} and model table #{table_name}" do
      allow(item_model).to receive(:table_name).and_return(table_name)
      executor.send(:typed_redaction_context, 'sql', { 'sql' => "SELECT quantity FROM #{source} AS item" })
      expect(safe_context).to have_received(:with_key_value_types).with({ 'quantity' => [quantity_type] }, raw: true)
    end
  end

  it 'retains every matching type when registered tables share a final segment' do
    registry['ArchivedItem'] = ['quantity']
    archived_type = double('archived quantity type')
    stub_const('ArchivedItem', double('ArchivedItem', table_name: 'archive.line_items',
                                                      type_for_attribute: archived_type))
    executor.send(:typed_redaction_context, 'sql', { 'sql' => 'SELECT quantity FROM PUBLIC.LINE_ITEMS' })
    expect(safe_context).to have_received(:with_key_value_types)
      .with({ 'quantity' => contain_exactly(quantity_type, archived_type) }, raw: true)
  end

  it 'does not attach a type from an unrelated table' do
    executor.send(:typed_redaction_context, 'sql', { 'sql' => 'SELECT id FROM orders' })
    expect(safe_context).to have_received(:with_key_value_types).with({}, raw: true)
  end
end
