# frozen_string_literal: true

require 'spec_helper'
require 'json'
require 'net/http'
require 'codebase_index'
require 'codebase_index/storage/vector_store'
require 'codebase_index/storage/qdrant'

RSpec.describe CodebaseIndex::Storage::VectorStore::Qdrant do
  let(:store) { described_class.new(url: 'http://localhost:6333', collection: 'test_collection') }
  let(:http) { instance_double(Net::HTTP) }

  before do
    allow(Net::HTTP).to receive(:new).and_return(http)
    allow(http).to receive(:use_ssl=)
    allow(http).to receive(:open_timeout=)
    allow(http).to receive(:read_timeout=)
    allow(http).to receive(:keep_alive_timeout=)
  end

  describe '#initialize' do
    it 'creates a store with url and collection' do
      expect(store).to be_a(described_class)
    end

    it 'accepts an optional api_key' do
      store_with_key = described_class.new(url: 'http://localhost:6333', collection: 'test', api_key: 'secret')
      expect(store_with_key).to be_a(described_class)
    end
  end

  describe '#ensure_collection!' do
    it 'sends a PUT request to create the collection' do
      response = instance_double(Net::HTTPSuccess, code: '200', body: '{"result":true}')
      allow(response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(true)
      allow(http).to receive(:request).and_return(response)

      store.ensure_collection!(dimensions: 384)

      expect(http).to have_received(:request) do |req|
        expect(req).to be_a(Net::HTTP::Put)
        expect(req.path).to eq('/collections/test_collection')
        body = JSON.parse(req.body)
        expect(body['vectors']['size']).to eq(384)
        expect(body['vectors']['distance']).to eq('Cosine')
      end
    end
  end

  describe '#store' do
    it 'sends a PUT request to upsert points' do
      response = instance_double(Net::HTTPSuccess, code: '200', body: '{"result":{"status":"completed"}}')
      allow(response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(true)
      allow(http).to receive(:request).and_return(response)

      store.store('doc1', [0.1, 0.2, 0.3], { type: 'model' })

      expect(http).to have_received(:request) do |req|
        expect(req).to be_a(Net::HTTP::Put)
        expect(req.path).to eq('/collections/test_collection/points')
        body = JSON.parse(req.body)
        point = body['points'].first
        expect(point['id']).to eq('doc1')
        expect(point['vector']).to eq([0.1, 0.2, 0.3])
        expect(point['payload']).to eq({ 'type' => 'model' })
      end
    end

    it 'raises on API error' do
      response = instance_double(Net::HTTPInternalServerError, code: '500', body: 'Internal error')
      allow(response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(false)
      allow(http).to receive(:request).and_return(response)

      expect { store.store('doc1', [0.1], {}) }.to raise_error(CodebaseIndex::Error, /Qdrant API error/)
    end
  end

  describe '#search' do
    let(:search_response_body) do
      {
        result: [
          { id: 'doc1', score: 0.95, payload: { type: 'model' } },
          { id: 'doc2', score: 0.80, payload: { type: 'service' } }
        ]
      }.to_json
    end

    before do
      response = instance_double(Net::HTTPSuccess, code: '200', body: search_response_body)
      allow(response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(true)
      allow(http).to receive(:request).and_return(response)
    end

    it 'returns an array of SearchResult objects' do
      results = store.search([0.1, 0.2, 0.3], limit: 10)

      expect(results).to all(be_a(CodebaseIndex::Storage::VectorStore::SearchResult))
      expect(results.size).to eq(2)
    end

    it 'maps score and metadata correctly' do
      results = store.search([0.1, 0.2, 0.3])

      expect(results.first.id).to eq('doc1')
      expect(results.first.score).to eq(0.95)
      expect(results.first.metadata).to eq({ 'type' => 'model' })
    end

    it 'sends the correct limit' do
      store.search([0.1, 0.2, 0.3], limit: 5)

      expect(http).to have_received(:request) do |req|
        body = JSON.parse(req.body)
        expect(body['limit']).to eq(5)
      end
    end

    it 'applies metadata filters using Qdrant must conditions' do
      store.search([0.1, 0.2, 0.3], filters: { type: 'model' })

      expect(http).to have_received(:request) do |req|
        body = JSON.parse(req.body)
        must_conditions = body['filter']['must']
        expect(must_conditions).to include({ 'key' => 'type', 'match' => { 'value' => 'model' } })
      end
    end

    it 'omits filter when filters are empty' do
      store.search([0.1, 0.2, 0.3], filters: {})

      expect(http).to have_received(:request) do |req|
        body = JSON.parse(req.body)
        expect(body).not_to have_key('filter')
      end
    end
  end

  describe '#delete' do
    it 'sends a POST request to delete a point by ID' do
      response = instance_double(Net::HTTPSuccess, code: '200', body: '{"result":{"status":"completed"}}')
      allow(response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(true)
      allow(http).to receive(:request).and_return(response)

      store.delete('doc1')

      expect(http).to have_received(:request) do |req|
        expect(req).to be_a(Net::HTTP::Post)
        expect(req.path).to eq('/collections/test_collection/points/delete')
        body = JSON.parse(req.body)
        expect(body['points']).to eq(['doc1'])
      end
    end
  end

  describe '#delete_by_filter' do
    it 'sends a POST request to delete by filter' do
      response = instance_double(Net::HTTPSuccess, code: '200', body: '{"result":{"status":"completed"}}')
      allow(response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(true)
      allow(http).to receive(:request).and_return(response)

      store.delete_by_filter({ type: 'model' })

      expect(http).to have_received(:request) do |req|
        expect(req).to be_a(Net::HTTP::Post)
        expect(req.path).to eq('/collections/test_collection/points/delete')
        body = JSON.parse(req.body)
        expect(body['filter']['must']).to include({ 'key' => 'type', 'match' => { 'value' => 'model' } })
      end
    end
  end

  describe '#count' do
    it 'returns the number of stored vectors' do
      response = instance_double(Net::HTTPSuccess, code: '200', body: '{"result":{"count":42}}')
      allow(response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(true)
      allow(http).to receive(:request).and_return(response)

      expect(store.count).to eq(42)
    end
  end

  describe 'HTTP timeout configuration' do
    it 'sets open_timeout on the HTTP connection' do
      response = instance_double(Net::HTTPSuccess, code: '200', body: '{"result":{"count":0}}')
      allow(response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(true)
      allow(http).to receive(:request).and_return(response)

      store.count

      expect(http).to have_received(:open_timeout=).with(10)
    end

    it 'sets read_timeout on the HTTP connection' do
      response = instance_double(Net::HTTPSuccess, code: '200', body: '{"result":{"count":0}}')
      allow(response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(true)
      allow(http).to receive(:request).and_return(response)

      store.count

      expect(http).to have_received(:read_timeout=).with(30)
    end
  end

  describe 'Interface compliance' do
    it 'includes VectorStore::Interface' do
      expect(described_class.ancestors).to include(CodebaseIndex::Storage::VectorStore::Interface)
    end
  end

  describe 'API key authentication' do
    it 'includes api-key header when api_key is provided' do
      store_with_key = described_class.new(url: 'http://localhost:6333', collection: 'test', api_key: 'secret-key')
      response = instance_double(Net::HTTPSuccess, code: '200', body: '{"result":{"count":0}}')
      allow(response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(true)
      allow(http).to receive(:request).and_return(response)

      store_with_key.count

      expect(http).to have_received(:request) do |req|
        expect(req['api-key']).to eq('secret-key')
      end
    end
  end
end
