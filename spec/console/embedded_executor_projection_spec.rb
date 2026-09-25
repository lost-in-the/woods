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
    [' orders.id ', ' line_items.quantity '],
    ['orders.id, line_items.quantity']
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
end
