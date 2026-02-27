# frozen_string_literal: true

require 'spec_helper'
require 'codebase_index/notion/client'

RSpec.describe CodebaseIndex::Notion::Client do
  subject(:client) { described_class.new(api_token: api_token, rate_limiter: rate_limiter) }

  let(:api_token) { 'secret_test_token_123' }
  let(:rate_limiter) { instance_double(CodebaseIndex::Notion::RateLimiter) }

  before do
    allow(rate_limiter).to receive(:throttle).and_yield
  end

  # Helper to stub Net::HTTP responses
  def stub_notion_request(status:, body:, **_options)
    response = build_stub_response(status, body)
    stub_http_client(response)
    response
  end

  def build_stub_response(status, body)
    response = instance_double(Net::HTTPResponse, code: status.to_s, body: JSON.generate(body))
    allow(response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(status >= 200 && status < 300)
    allow(response).to receive(:[]).with('Retry-After').and_return(nil)
    response
  end

  def stub_http_client(response)
    http = instance_double(Net::HTTP)
    allow(Net::HTTP).to receive(:new).and_return(http)
    allow(http).to receive(:use_ssl=)
    allow(http).to receive(:open_timeout=)
    allow(http).to receive(:read_timeout=)
    allow(http).to receive(:request).and_return(response)
  end

  describe '#initialize' do
    it 'requires an api_token' do
      expect { described_class.new(api_token: nil) }.to raise_error(ArgumentError)
    end

    it 'requires a non-empty api_token' do
      expect { described_class.new(api_token: '') }.to raise_error(ArgumentError)
    end

    it 'accepts valid api_token' do
      expect(client).to be_a(described_class)
    end

    it 'uses default RateLimiter when none provided' do
      default_client = described_class.new(api_token: api_token)
      expect(default_client).to be_a(described_class)
    end
  end

  describe '#create_page' do
    let(:database_id) { 'db-uuid-123' }
    let(:properties) do
      { 'Name' => { title: [{ text: { content: 'Test' } }] } }
    end

    it 'sends POST to /v1/pages with correct payload' do
      stub_notion_request(
        method: :post, path: 'pages',
        status: 200, body: { 'id' => 'page-123', 'object' => 'page' }
      )

      result = client.create_page(database_id: database_id, properties: properties)
      expect(result['id']).to eq('page-123')
    end

    it 'includes children when provided' do
      stub_notion_request(
        method: :post, path: 'pages',
        status: 200, body: { 'id' => 'page-456', 'object' => 'page' }
      )

      result = client.create_page(
        database_id: database_id,
        properties: properties,
        children: [{ object: 'block', type: 'paragraph' }]
      )
      expect(result['id']).to eq('page-456')
    end

    it 'throttles requests through rate limiter' do
      stub_notion_request(
        method: :post, path: 'pages',
        status: 200, body: { 'id' => 'page-789' }
      )

      client.create_page(database_id: database_id, properties: properties)
      expect(rate_limiter).to have_received(:throttle)
    end
  end

  describe '#update_page' do
    let(:page_id) { 'page-123' }
    let(:properties) do
      { 'Status' => { select: { name: 'Active' } } }
    end

    it 'sends PATCH to /v1/pages/{id}' do
      stub_notion_request(
        method: :patch, path: "pages/#{page_id}",
        status: 200, body: { 'id' => page_id, 'object' => 'page' }
      )

      result = client.update_page(page_id: page_id, properties: properties)
      expect(result['id']).to eq(page_id)
    end
  end

  describe '#query_database' do
    let(:database_id) { 'db-uuid-456' }

    it 'sends POST to /v1/databases/{id}/query' do
      stub_notion_request(
        method: :post, path: "databases/#{database_id}/query",
        status: 200, body: { 'results' => [{ 'id' => 'page-1' }], 'has_more' => false }
      )

      result = client.query_database(database_id: database_id)
      expect(result['results']).to have_attributes(size: 1)
    end

    it 'passes filter when provided' do
      stub_notion_request(
        method: :post, path: "databases/#{database_id}/query",
        status: 200, body: { 'results' => [], 'has_more' => false }
      )

      filter = { property: 'Name', title: { equals: 'Users' } }
      result = client.query_database(database_id: database_id, filter: filter)
      expect(result['results']).to eq([])
    end
  end

  describe '#query_all' do
    let(:database_id) { 'db-uuid-789' }

    it 'returns all results when has_more is false' do
      stub_notion_request(
        method: :post, path: "databases/#{database_id}/query",
        status: 200, body: { 'results' => [{ 'id' => 'p1' }, { 'id' => 'p2' }], 'has_more' => false }
      )

      results = client.query_all(database_id: database_id)
      expect(results).to have_attributes(size: 2)
    end

    it 'paginates when has_more is true' do
      page1_response = instance_double(
        Net::HTTPResponse,
        code: '200',
        body: JSON.generate({
                              'results' => [{ 'id' => 'p1' }],
                              'has_more' => true,
                              'next_cursor' => 'cursor-abc'
                            })
      )
      page2_response = instance_double(
        Net::HTTPResponse,
        code: '200',
        body: JSON.generate({
                              'results' => [{ 'id' => 'p2' }],
                              'has_more' => false
                            })
      )

      allow(page1_response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(true)
      allow(page2_response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(true)

      http = instance_double(Net::HTTP)
      allow(Net::HTTP).to receive(:new).and_return(http)
      allow(http).to receive(:use_ssl=)
      allow(http).to receive(:open_timeout=)
      allow(http).to receive(:read_timeout=)
      allow(http).to receive(:request).and_return(page1_response, page2_response)

      results = client.query_all(database_id: database_id)
      expect(results.map { |r| r['id'] }).to eq(%w[p1 p2])
    end
  end

  describe '#find_page_by_title' do
    let(:database_id) { 'db-uuid-title' }

    it 'returns page when found' do
      page_data = { 'id' => 'page-found', 'properties' => { 'Name' => {} } }
      stub_notion_request(
        method: :post, path: "databases/#{database_id}/query",
        status: 200, body: { 'results' => [page_data], 'has_more' => false }
      )

      result = client.find_page_by_title(database_id: database_id, title: 'users')
      expect(result['id']).to eq('page-found')
    end

    it 'returns nil when not found' do
      stub_notion_request(
        method: :post, path: "databases/#{database_id}/query",
        status: 200, body: { 'results' => [], 'has_more' => false }
      )

      result = client.find_page_by_title(database_id: database_id, title: 'nonexistent')
      expect(result).to be_nil
    end
  end

  describe 'error handling' do
    it 'raises on 400 Bad Request' do
      stub_notion_request(
        method: :post, path: 'pages',
        status: 400, body: { 'message' => 'Invalid request', 'code' => 'validation_error' }
      )

      expect do
        client.create_page(database_id: 'db', properties: {})
      end.to raise_error(CodebaseIndex::Error, /400.*Invalid request/)
    end

    it 'raises on 401 Unauthorized' do
      stub_notion_request(
        method: :post, path: 'pages',
        status: 401, body: { 'message' => 'API token is invalid', 'code' => 'unauthorized' }
      )

      expect do
        client.create_page(database_id: 'db', properties: {})
      end.to raise_error(CodebaseIndex::Error, /401/)
    end

    it 'retries on 429 Too Many Requests' do
      retry_response = instance_double(
        Net::HTTPResponse,
        code: '429',
        body: JSON.generate({ 'message' => 'Rate limited' })
      )
      allow(retry_response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(false)
      allow(retry_response).to receive(:[]).with('Retry-After').and_return('1')

      success_response = instance_double(
        Net::HTTPResponse,
        code: '200',
        body: JSON.generate({ 'id' => 'page-ok' })
      )
      allow(success_response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(true)

      http = instance_double(Net::HTTP)
      allow(Net::HTTP).to receive(:new).and_return(http)
      allow(http).to receive(:use_ssl=)
      allow(http).to receive(:open_timeout=)
      allow(http).to receive(:read_timeout=)
      allow(http).to receive(:request).and_return(retry_response, success_response)
      allow(client).to receive(:sleep)

      result = client.create_page(database_id: 'db', properties: {})
      expect(result['id']).to eq('page-ok')
    end

    it 'raises after max retries on persistent 429' do
      retry_response = instance_double(
        Net::HTTPResponse,
        code: '429',
        body: JSON.generate({ 'message' => 'Rate limited' })
      )
      allow(retry_response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(false)
      allow(retry_response).to receive(:[]).with('Retry-After').and_return('1')

      http = instance_double(Net::HTTP)
      allow(Net::HTTP).to receive(:new).and_return(http)
      allow(http).to receive(:use_ssl=)
      allow(http).to receive(:open_timeout=)
      allow(http).to receive(:read_timeout=)
      allow(http).to receive(:request).and_return(retry_response)
      allow(client).to receive(:sleep)

      expect do
        client.create_page(database_id: 'db', properties: {})
      end.to raise_error(CodebaseIndex::Error, /429/)
    end
  end
end
