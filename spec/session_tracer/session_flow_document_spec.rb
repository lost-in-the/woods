# frozen_string_literal: true

require 'spec_helper'
require 'json'
require 'codebase_index/session_tracer/session_flow_document'

RSpec.describe CodebaseIndex::SessionTracer::SessionFlowDocument do
  let(:steps) do
    [
      {
        index: 0,
        method: 'POST',
        path: '/orders',
        controller: 'OrdersController',
        action: 'create',
        status: 302,
        duration_ms: 145,
        unit_refs: %w[OrdersController Order OrderPolicy],
        side_effects: [
          { type: :job, identifier: 'SyncOrderJob', trigger_step: 'OrdersController#create' }
        ]
      },
      {
        index: 1,
        method: 'GET',
        path: '/orders/1',
        controller: 'OrdersController',
        action: 'show',
        status: 200,
        duration_ms: 12,
        unit_refs: %w[OrdersController Order],
        side_effects: []
      }
    ]
  end

  let(:context_pool) do
    {
      'OrdersController' => {
        type: 'controller',
        file_path: 'app/controllers/orders_controller.rb',
        source_code: "class OrdersController < ApplicationController\n  def create; end\n  def show; end\nend"
      },
      'Order' => {
        type: 'model',
        file_path: 'app/models/order.rb',
        source_code: "class Order < ApplicationRecord\n  belongs_to :user\nend"
      }
    }
  end

  let(:side_effects) do
    [
      { type: :job, identifier: 'SyncOrderJob', trigger_step: 'OrdersController#create' },
      { type: :mailer, identifier: 'OrderMailer#confirmation', trigger_step: 'OrdersController#create' }
    ]
  end

  let(:dependency_map) do
    {
      'OrdersController' => %w[Order OrderPolicy SyncOrderJob OrderMailer],
      'Order' => %w[User LineItem]
    }
  end

  let(:generated_at) { '2026-02-13T10:00:00Z' }

  let(:doc) do
    described_class.new(
      session_id: 'abc123',
      steps: steps,
      context_pool: context_pool,
      side_effects: side_effects,
      dependency_map: dependency_map,
      token_count: 720,
      generated_at: generated_at
    )
  end

  describe '#initialize' do
    it 'stores all attributes' do
      expect(doc.session_id).to eq('abc123')
      expect(doc.steps).to eq(steps)
      expect(doc.context_pool).to eq(context_pool)
      expect(doc.side_effects).to eq(side_effects)
      expect(doc.dependency_map).to eq(dependency_map)
      expect(doc.token_count).to eq(720)
      expect(doc.generated_at).to eq(generated_at)
    end

    it 'defaults generated_at to current time' do
      doc = described_class.new(session_id: 'test')
      expect(doc.generated_at).to be_a(String)
      expect(doc.generated_at).to match(/\d{4}-\d{2}-\d{2}T/)
    end

    it 'defaults optional fields' do
      doc = described_class.new(session_id: 'test')
      expect(doc.steps).to eq([])
      expect(doc.context_pool).to eq({})
      expect(doc.side_effects).to eq([])
      expect(doc.dependency_map).to eq({})
      expect(doc.token_count).to eq(0)
    end
  end

  describe '#to_h' do
    it 'returns a JSON-serializable hash' do
      hash = doc.to_h

      expect(hash[:session_id]).to eq('abc123')
      expect(hash[:steps]).to eq(steps)
      expect(hash[:context_pool]).to eq(context_pool)
      expect(hash[:token_count]).to eq(720)
    end

    it 'round-trips through JSON' do
      json = JSON.generate(doc.to_h)
      parsed = JSON.parse(json)

      expect(parsed['session_id']).to eq('abc123')
      expect(parsed['steps'].size).to eq(2)
      expect(parsed['context_pool'].keys).to contain_exactly('OrdersController', 'Order')
    end
  end

  describe '.from_h' do
    it 'reconstructs from symbol-keyed hash' do
      restored = described_class.from_h(doc.to_h)

      expect(restored.session_id).to eq('abc123')
      expect(restored.steps.size).to eq(2)
      expect(restored.context_pool.keys).to contain_exactly(:OrdersController, :Order)
      expect(restored.token_count).to eq(720)
    end

    it 'reconstructs from string-keyed hash (JSON round-trip)' do
      json = JSON.generate(doc.to_h)
      parsed = JSON.parse(json)
      restored = described_class.from_h(parsed)

      expect(restored.session_id).to eq('abc123')
      expect(restored.steps.size).to eq(2)
    end

    it 'handles missing optional fields' do
      restored = described_class.from_h({ session_id: 'test' })

      expect(restored.session_id).to eq('test')
      expect(restored.steps).to eq([])
      expect(restored.context_pool).to eq({})
    end
  end

  describe '#to_markdown' do
    it 'includes session header' do
      md = doc.to_markdown
      expect(md).to include('## Session: abc123')
    end

    it 'includes timeline with request details' do
      md = doc.to_markdown
      expect(md).to include('POST /orders')
      expect(md).to include('OrdersController#create')
      expect(md).to include('[302]')
      expect(md).to include('GET /orders/1')
    end

    it 'includes side effects section' do
      md = doc.to_markdown
      expect(md).to include('### Side Effects')
      expect(md).to include('SyncOrderJob')
      expect(md).to include('OrderMailer#confirmation')
    end

    it 'includes code units with source' do
      md = doc.to_markdown
      expect(md).to include('#### OrdersController (controller)')
      expect(md).to include('class OrdersController')
    end

    it 'includes dependency map' do
      md = doc.to_markdown
      expect(md).to include('### Dependencies')
      expect(md).to include('OrdersController → Order, OrderPolicy')
    end
  end

  describe '#to_context' do
    it 'wraps in session_context tags' do
      xml = doc.to_context
      expect(xml).to start_with('<session_context session_id="abc123"')
      expect(xml).to end_with("</session_context>\n".rstrip)
    end

    it 'includes request and unit counts in attributes' do
      xml = doc.to_context
      expect(xml).to include('requests="2"')
      expect(xml).to include('units="2"')
      expect(xml).to include('tokens="720"')
    end

    it 'includes timeline' do
      xml = doc.to_context
      expect(xml).to include('<session_timeline>')
      expect(xml).to include('POST /orders')
      expect(xml).to include('</session_timeline>')
    end

    it 'includes unit tags with attributes and source' do
      xml = doc.to_context
      expect(xml).to include('<unit identifier="OrdersController" type="controller"')
      expect(xml).to include('class OrdersController')
      expect(xml).to include('</unit>')
    end

    it 'includes side effects section' do
      xml = doc.to_context
      expect(xml).to include('<side_effects>')
      expect(xml).to include('SyncOrderJob')
      expect(xml).to include('</side_effects>')
    end

    it 'includes dependencies section' do
      xml = doc.to_context
      expect(xml).to include('<dependencies>')
      expect(xml).to include('OrdersController → Order, OrderPolicy')
      expect(xml).to include('</dependencies>')
    end
  end
end
