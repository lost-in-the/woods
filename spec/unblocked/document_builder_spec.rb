# frozen_string_literal: true

require 'spec_helper'
require 'woods/unblocked/document_builder'

RSpec.describe Woods::Unblocked::DocumentBuilder do
  subject(:builder) { described_class.new(repo_url: 'https://github.com/org/repo') }

  describe '#build' do
    it 'builds a document for a model unit' do
      doc = builder.build({
                            'type' => 'model',
                            'identifier' => 'Order',
                            'file_path' => 'app/models/order.rb',
                            'metadata' => { 'table_name' => 'orders' },
                            'dependencies' => [],
                            'dependents' => []
                          })
      expect(doc[:title]).to eq('Order (model)')
      expect(doc[:uri]).to eq('https://github.com/org/repo/blob/main/app/models/order.rb')
      expect(doc[:body]).to include('Order')
    end

    it 'builds a document for a controller unit' do
      doc = builder.build({
                            'type' => 'controller',
                            'identifier' => 'OrdersController',
                            'file_path' => 'app/controllers/orders_controller.rb',
                            'metadata' => { 'actions' => %w[index show] }
                          })
      expect(doc[:title]).to eq('OrdersController (controller)')
      expect(doc[:uri]).to end_with('app/controllers/orders_controller.rb')
    end

    it 'handles a unit with a missing file_path (no blob URL)' do
      doc = builder.build({
                            'type' => 'service',
                            'identifier' => 'X',
                            'file_path' => nil
                          })
      expect(doc[:uri]).to eq('https://github.com/org/repo')
    end

    it 'strips trailing slash from repo_url' do
      b = described_class.new(repo_url: 'https://example.com/')
      doc = b.build({ 'type' => 'model', 'identifier' => 'X', 'file_path' => 'a.rb' })
      expect(doc[:uri]).to eq('https://example.com/blob/main/a.rb')
    end

    it 'falls back to generic body for unknown unit types' do
      doc = builder.build({
                            'type' => 'unknown_type',
                            'identifier' => 'Mystery',
                            'file_path' => 'a.rb'
                          })
      expect(doc[:title]).to eq('Mystery (unknown_type)')
      expect(doc[:body]).to be_a(String)
    end

    it 'redacts credentials embedded in text' do
      doc = builder.build({
                            'type' => 'model',
                            'identifier' => 'Secret',
                            'file_path' => 'app/models/secret.rb',
                            'metadata' => {
                              'columns' => [{ 'name' => 'key',
                                              'comment' => 'default: sk_live_51Sx7cbE0QMvj9FH5xhCjCEIl6TDZXZRpfYE' }]
                            }
                          })
      expect(doc[:body]).not_to include('sk_live_51Sx7cbE0QMvj9FH5xhCjCEIl6TDZXZRpfYE')
    end
  end

  describe '#uri_for' do
    it 'returns the GitHub blob URL for a unit with a file_path' do
      uri = builder.uri_for({ 'file_path' => 'app/models/order.rb' })
      expect(uri).to eq('https://github.com/org/repo/blob/main/app/models/order.rb')
    end

    it 'returns the repo URL when file_path is missing' do
      expect(builder.uri_for({ 'file_path' => nil })).to eq('https://github.com/org/repo')
    end

    it 'matches the uri produced by #build for the same unit' do
      unit = { 'type' => 'model', 'identifier' => 'Order', 'file_path' => 'app/models/order.rb' }
      expect(builder.uri_for(unit)).to eq(builder.build(unit)[:uri])
    end
  end

  # The skip-if-unchanged mechanism in the exporter hashes the built body.
  # If the body depends on input *ordering* (association/dependent/etc. order),
  # an extraction that reorders unchanged data re-pushes everything and
  # incremental silently degrades to full. The body must be a function of the
  # *content*, not the order.
  describe 'deterministic body output' do
    let(:model_unit) do
      {
        'type' => 'model',
        'identifier' => 'Order',
        'file_path' => 'app/models/order.rb',
        'metadata' => {
          'table_name' => 'orders',
          'associations' => [
            { 'type' => 'belongs_to', 'target' => 'Zebra' },
            { 'type' => 'belongs_to', 'target' => 'Apple' },
            { 'type' => 'has_many', 'target' => 'LineItems' },
            { 'type' => 'has_many', 'target' => 'Comments' }
          ],
          'enums' => { 'status' => %w[open closed], 'kind' => %w[a b] },
          'scopes' => [{ 'name' => 'recent' }, { 'name' => 'active' }],
          'inlined_concerns' => %w[Trackable Auditable],
          'callbacks' => [
            { 'type' => 'before_save', 'filter' => 'normalize' },
            { 'type' => 'after_create', 'filter' => 'notify' }
          ]
        },
        'dependencies' => [],
        'dependents' => [
          { 'type' => 'controller', 'identifier' => 'ZOrdersController' },
          { 'type' => 'controller', 'identifier' => 'AOrdersController' },
          { 'type' => 'job', 'identifier' => 'ZJob' },
          { 'type' => 'job', 'identifier' => 'AJob' }
        ]
      }
    end

    def reversed(unit)
      u = Marshal.load(Marshal.dump(unit))
      u['metadata']['associations'].reverse!
      u['metadata']['scopes'].reverse!
      u['metadata']['inlined_concerns'].reverse!
      u['metadata']['callbacks'].reverse!
      u['metadata']['enums'] = u['metadata']['enums'].to_a.reverse.to_h
      u['dependents'].reverse!
      u
    end

    it 'produces identical bytes when built twice from the same data' do
      expect(builder.build(model_unit)[:body]).to eq(builder.build(model_unit)[:body])
    end

    it 'produces identical bytes regardless of input collection order' do
      expect(builder.build(model_unit)[:body]).to eq(builder.build(reversed(model_unit))[:body])
    end
  end
end
