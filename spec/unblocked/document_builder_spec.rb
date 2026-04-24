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
end
