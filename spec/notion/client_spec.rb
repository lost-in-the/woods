# frozen_string_literal: true

require 'spec_helper'
require 'woods/notion/client'

RSpec.describe Woods::Notion::Client do
  subject(:client) { described_class.new(api_token: api_token, rate_limiter: rate_limiter) }

  let(:api_token) { 'secret_test_token_123' }
  let(:rate_limiter) { instance_double(Woods::Notion::RateLimiter) }

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
      end.to raise_error(Woods::Error, /400.*Invalid request/)
    end

    it 'raises on 401 Unauthorized' do
      stub_notion_request(
        method: :post, path: 'pages',
        status: 401, body: { 'message' => 'API token is invalid', 'code' => 'unauthorized' }
      )

      # Typed, so the exporter can abort the run rather than recording one
      # error per unit and grinding through the whole sync at 3 req/sec
      # (#217). Still a Woods::Error, so existing rescues are unaffected.
      expect do
        client.create_page(database_id: 'db', properties: {})
      end.to raise_error(Woods::Notion::AuthenticationError, /401/)
    end

    it 'raises AuthenticationError on 403 Forbidden' do
      stub_notion_request(
        method: :post, path: 'pages',
        status: 403, body: { 'message' => 'Integration lacks access', 'code' => 'restricted_resource' }
      )

      expect do
        client.create_page(database_id: 'db', properties: {})
      end.to raise_error(Woods::Notion::AuthenticationError, /403/)
    end

    it 'raises a plain Woods::Error for non-auth statuses' do
      stub_notion_request(
        method: :post, path: 'pages',
        status: 400, body: { 'message' => 'Invalid request' }
      )

      expect do
        client.create_page(database_id: 'db', properties: {})
      end.to raise_error(Woods::Error) { |e|
        expect(e).not_to be_a(Woods::Notion::AuthenticationError)
      }
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
      end.to raise_error(Woods::Error, /429/)
    end
  end

  describe 'verb-aware network retry' do
    let(:http) { instance_double(Net::HTTP) }

    before do
      allow(Net::HTTP).to receive(:new).and_return(http)
      allow(http).to receive(:use_ssl=)
      allow(http).to receive(:open_timeout=)
      allow(http).to receive(:read_timeout=)
      allow(client).to receive(:sleep)
    end

    def success_response(body)
      response = instance_double(Net::HTTPResponse, code: '200', body: JSON.generate(body))
      allow(response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(true)
      response
    end

    def fail_then_succeed(error_class, body)
      response = success_response(body)
      calls = 0
      allow(http).to receive(:request) do
        calls += 1
        raise error_class if calls == 1

        response
      end
      -> { calls }
    end

    def always_fail(error_class)
      calls = 0
      allow(http).to receive(:request) do
        calls += 1
        raise error_class
      end
      -> { calls }
    end

    describe 'POST on Net::ReadTimeout (mid-exchange: may have been committed)' do
      it 'raises an error noting the operation may or may not have been applied' do
        always_fail(Net::ReadTimeout)

        expect do
          client.create_page(database_id: 'db', properties: {})
        end.to raise_error(Woods::Error, /may or may not have been applied/)
      end

      it 'gives up after a single attempt instead of retrying' do
        calls = always_fail(Net::ReadTimeout)

        expect do
          client.create_page(database_id: 'db', properties: {})
        end.to raise_error(Woods::Error)
        expect(calls.call).to eq(1)
      end
    end

    it 'classifies PATCH like POST: no retry on Net::ReadTimeout' do
      calls = always_fail(Net::ReadTimeout)

      expect do
        client.update_page(page_id: 'page-1', properties: {})
      end.to raise_error(Woods::Error, /may or may not have been applied/)
      expect(calls.call).to eq(1)
    end

    it 'does not retry a POST on ECONNRESET (mid-exchange)' do
      calls = always_fail(Errno::ECONNRESET)

      expect do
        client.create_page(database_id: 'db', properties: {})
      end.to raise_error(Woods::Error, /may or may not have been applied/)
      expect(calls.call).to eq(1)
    end

    it 'retries a POST on Net::OpenTimeout (connection never established)' do
      calls = fail_then_succeed(Net::OpenTimeout, { 'id' => 'page-ok' })

      result = client.create_page(database_id: 'db', properties: {})
      expect(result['id']).to eq('page-ok')
      expect(calls.call).to eq(2)
    end

    it 'retries a POST on ECONNREFUSED (connection never established)' do
      calls = fail_then_succeed(Errno::ECONNREFUSED, { 'id' => 'page-ok' })

      result = client.create_page(database_id: 'db', properties: {})
      expect(result['id']).to eq('page-ok')
      expect(calls.call).to eq(2)
    end

    # #query_database is a POST, but it's a read — nothing is committed
    # server-side that a repeat could double-apply. Classifying it like
    # create_page's non-idempotent POST meant a ReadTimeout mid-exchange
    # failed the whole unit instead of retrying a request that was always
    # safe to repeat.
    it 'retries a POST query_database on Net::ReadTimeout (read-only, safe to repeat)' do
      calls = fail_then_succeed(Net::ReadTimeout, { 'results' => [], 'has_more' => false })

      result = client.query_database(database_id: 'db')
      expect(result['results']).to eq([])
      expect(calls.call).to eq(2)
    end

    it 'retries find_page_by_title on Net::ReadTimeout (delegates to query_database)' do
      calls = fail_then_succeed(Net::ReadTimeout, { 'results' => [{ 'id' => 'p1' }], 'has_more' => false })

      result = client.find_page_by_title(database_id: 'db', title: 'users')
      expect(result['id']).to eq('p1')
      expect(calls.call).to eq(2)
    end

    it 'still retries a GET on Net::ReadTimeout (idempotent verb)' do
      # No public Notion endpoint issues a GET today, so drive the private
      # request path directly to pin the idempotent classification.
      calls = fail_then_succeed(Net::ReadTimeout, { 'ok' => true })

      result = client.send(:request, :get, 'users')
      expect(result['ok']).to be(true)
      expect(calls.call).to eq(2)
    end

    it 'retries a POST on 429 honoring the Retry-After delay' do
      throttled = instance_double(Net::HTTPResponse, code: '429', body: JSON.generate({ 'message' => 'Rate limited' }))
      allow(throttled).to receive(:is_a?).with(Net::HTTPSuccess).and_return(false)
      allow(throttled).to receive(:[]).with('Retry-After').and_return('7')
      allow(http).to receive(:request).and_return(throttled, success_response({ 'id' => 'page-after-429' }))

      result = client.create_page(database_id: 'db', properties: {})
      expect(result['id']).to eq('page-after-429')
      expect(client).to have_received(:sleep).with(7.0)
    end

    it 'does not retry a POST create_page on 503 (no idempotency key to offer Notion)' do
      # Notion offers no idempotency key, and a 503 can be synthesized by an
      # intermediary in front of an origin that already committed the
      # create — retrying risks a duplicate page the exporter can't reconcile.
      unavailable = instance_double(Net::HTTPResponse, code: '503', body: JSON.generate({ 'message' => 'down' }))
      allow(unavailable).to receive(:is_a?).with(Net::HTTPSuccess).and_return(false)
      allow(unavailable).to receive(:[]).with('Retry-After').and_return(nil)
      allow(http).to receive(:request).and_return(unavailable, success_response({ 'id' => 'page-after-503' }))

      expect do
        client.create_page(database_id: 'db', properties: {})
      end.to raise_error(Woods::Error, /may or may not have been applied/)
    end

    it 'still retries a POST query_database on 503 (a read, safe to repeat)' do
      unavailable = instance_double(Net::HTTPResponse, code: '503', body: JSON.generate({ 'message' => 'down' }))
      allow(unavailable).to receive(:is_a?).with(Net::HTTPSuccess).and_return(false)
      allow(unavailable).to receive(:[]).with('Retry-After').and_return(nil)
      allow(http).to receive(:request).and_return(
        unavailable, success_response({ 'results' => [], 'has_more' => false })
      )

      result = client.query_database(database_id: 'db')
      expect(result['results']).to eq([])
    end

    it 'still raises on a POST 500 (ambiguous 5xx is not retried)' do
      broken = instance_double(Net::HTTPResponse, code: '500', body: JSON.generate({ 'message' => 'boom' }))
      allow(broken).to receive(:is_a?).with(Net::HTTPSuccess).and_return(false)
      allow(http).to receive(:request).and_return(broken)

      expect do
        client.create_page(database_id: 'db', properties: {})
      end.to raise_error(Woods::Error, /500/)
    end
  end

  describe 'bearer-token redaction in errors' do
    it 'redacts the api_token from a reflected error message body' do
      reflected_response = instance_double(
        Net::HTTPResponse,
        code: '400',
        body: JSON.generate({ 'message' => "Bad token: Bearer #{api_token}" })
      )
      allow(reflected_response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(false)

      http = instance_double(Net::HTTP)
      allow(Net::HTTP).to receive(:new).and_return(http)
      allow(http).to receive(:use_ssl=)
      allow(http).to receive(:open_timeout=)
      allow(http).to receive(:read_timeout=)
      allow(http).to receive(:request).and_return(reflected_response)

      expect do
        client.create_page(database_id: 'db', properties: {})
      end.to raise_error(Woods::Error) { |err|
        expect(err.message).not_to include(api_token)
        expect(err.message).to include('[REDACTED]')
      }
    end

    it 'redacts the api_token from a network error message after retry exhaustion' do
      http = instance_double(Net::HTTP)
      allow(Net::HTTP).to receive(:new).and_return(http)
      allow(http).to receive(:use_ssl=)
      allow(http).to receive(:open_timeout=)
      allow(http).to receive(:read_timeout=)
      leaky_error = Net::OpenTimeout.new("request failed with Bearer #{api_token}")
      allow(http).to receive(:request).and_raise(leaky_error)
      allow(client).to receive(:sleep)

      expect do
        client.create_page(database_id: 'db', properties: {})
      end.to raise_error(Woods::Error) { |err|
        expect(err.message).not_to include(api_token)
        expect(err.message).to include('[REDACTED]')
      }
    end
  end
end
