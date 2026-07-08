# frozen_string_literal: true

require 'spec_helper'
require 'woods/svelte_flow/mermaid_renderer'

RSpec.describe Woods::SvelteFlow::MermaidRenderer do
  subject(:renderer) { described_class.new }

  let(:payload) do
    {
      'nodes' => [
        { 'id' => 'Order', 'type' => 'model', 'data' => { 'columns' => [
          { 'name' => 'id', 'type' => 'bigint', 'primary' => true, 'foreign' => false },
          { 'name' => 'account_id', 'type' => 'bigint', 'primary' => false, 'foreign' => true }
        ] } },
        { 'id' => 'Account', 'type' => 'model', 'data' => { 'columns' => [
          { 'name' => 'id', 'type' => 'bigint', 'primary' => true }
        ] } },
        { 'id' => 'ShippingProfile::Method', 'type' => 'model', 'data' => {} },
        { 'id' => 'OrdersController', 'type' => 'controller', 'data' => {} }
      ],
      'edges' => [
        { 'source' => 'Order', 'target' => 'Account', 'type' => 'association', 'data' => { 'via' => 'belongs_to' } },
        { 'source' => 'Cart', 'target' => 'Account', 'type' => 'association',
          'data' => { 'via' => 'has_and_belongs_to_many' } },
        { 'source' => 'OrdersController', 'target' => 'Order', 'type' => 'default',
          'data' => { 'via' => 'code_reference' } }
      ]
    }
  end

  let(:output) { renderer.render(payload) }

  it 'starts with the erDiagram header' do
    expect(output).to start_with("erDiagram\n")
  end

  it 'emits model columns as attributes with PK/FK constraints' do
    expect(output).to include("  Order {\n    bigint id PK\n    bigint account_id FK\n  }")
  end

  it 'emits an empty entity block for columnless units so they still appear' do
    expect(output).to include("  OrdersController {\n  }")
  end

  it 'sanitizes :: in entity names' do
    expect(output).to include('ShippingProfile__Method {')
    expect(output).not_to include('ShippingProfile::Method')
  end

  it 'renders FK→PK associations as many-to-one crow\'s foot with the macro label' do
    expect(output).to include('Order }o--|| Account : "belongs_to"')
  end

  it 'renders habtm as many-to-many' do
    expect(output).to include('Cart }o--o{ Account : "has_and_belongs_to_many"')
  end

  it 'renders generic code edges as a dashed non-identifying relationship' do
    expect(output).to include('OrdersController }o..o{ Order : "code_reference"')
  end

  it 'defaults a missing column type to string' do
    out = renderer.render('nodes' => [{ 'id' => 'X', 'data' => { 'columns' => [{ 'name' => 'c' }] } }], 'edges' => [])
    expect(out).to include('string c')
  end

  it 'handles an empty payload' do
    expect(renderer.render({})).to eq("erDiagram\n")
  end
end
