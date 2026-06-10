# frozen_string_literal: true

require 'spec_helper'
require 'woods'
require 'woods/unblocked/client'

RSpec.describe Woods::Unblocked::Client do
  subject(:client) { described_class.new(api_token: api_token, rate_limiter: rate_limiter) }

  let(:api_token) { 'ubk_test_token' }
  let(:rate_limiter) { instance_double(Woods::Unblocked::RateLimiter) }

  before do
    allow(rate_limiter).to receive(:track).and_yield
  end

  describe '#initialize' do
    it 'requires an api_token' do
      expect { described_class.new(api_token: nil) }.to raise_error(ArgumentError)
    end

    it 'rejects blank api_token' do
      expect { described_class.new(api_token: '   ') }.to raise_error(ArgumentError)
    end

    it 'accepts a valid token' do
      expect(described_class.new(api_token: 'ubk_x')).to be_a(described_class)
    end
  end

  describe '#put_document (happy path)' do
    it 'sends a PUT /documents with the expected payload' do
      success = instance_double(Net::HTTPSuccess, body: JSON.generate({ 'id' => 'doc-1' }), code: '200')
      allow(success).to receive(:is_a?).with(Net::HTTPSuccess).and_return(true)

      http = instance_double(Net::HTTP)
      allow(Net::HTTP).to receive(:new).and_return(http)
      allow(http).to receive(:use_ssl=)
      allow(http).to receive(:open_timeout=)
      allow(http).to receive(:read_timeout=)
      captured = nil
      allow(http).to receive(:request) do |req|
        captured = req
        success
      end

      result = client.put_document(
        collection_id: 'col-uuid',
        title: 'Order (model)',
        body: "# Order\nsome body",
        uri: 'https://example.com/models/order.rb'
      )
      expect(result).to eq('id' => 'doc-1')
      expect(captured).to be_a(Net::HTTP::Put)
      expect(captured['Authorization']).to eq("Bearer #{api_token}")
      parsed_body = JSON.parse(captured.body)
      expect(parsed_body).to include('collectionId' => 'col-uuid', 'uri' => 'https://example.com/models/order.rb')
    end
  end

  describe 'retry on 429' do
    it 'retries up to MAX_RETRIES and eventually succeeds' do
      retry_resp = instance_double(Net::HTTPResponse, code: '429', body: JSON.generate({ 'message' => 'slow' }))
      allow(retry_resp).to receive(:is_a?).with(Net::HTTPSuccess).and_return(false)
      allow(retry_resp).to receive(:[]).with('Retry-After').and_return('0')

      success = instance_double(Net::HTTPSuccess, code: '200', body: JSON.generate({ 'id' => 'doc-2' }))
      allow(success).to receive(:is_a?).with(Net::HTTPSuccess).and_return(true)

      http = instance_double(Net::HTTP)
      allow(Net::HTTP).to receive(:new).and_return(http)
      allow(http).to receive(:use_ssl=)
      allow(http).to receive(:open_timeout=)
      allow(http).to receive(:read_timeout=)
      allow(http).to receive(:request).and_return(retry_resp, success)
      allow(client).to receive(:sleep)

      result = client.put_document(collection_id: 'c', title: 't', body: 'b', uri: 'u')
      expect(result['id']).to eq('doc-2')
    end

    it 'raises Woods::Error after persistent 429' do
      retry_resp = instance_double(Net::HTTPResponse, code: '429', body: JSON.generate({ 'message' => 'slow' }))
      allow(retry_resp).to receive(:is_a?).with(Net::HTTPSuccess).and_return(false)
      allow(retry_resp).to receive(:[]).with('Retry-After').and_return('0')

      http = instance_double(Net::HTTP)
      allow(Net::HTTP).to receive(:new).and_return(http)
      allow(http).to receive(:use_ssl=)
      allow(http).to receive(:open_timeout=)
      allow(http).to receive(:read_timeout=)
      allow(http).to receive(:request).and_return(retry_resp)
      allow(client).to receive(:sleep)

      expect { client.put_document(collection_id: 'c', title: 't', body: 'b', uri: 'u') }
        .to raise_error(Woods::Error, /429/)
    end
  end

  describe 'error responses' do
    it 'raises a descriptive error on 401' do
      err = instance_double(Net::HTTPResponse, code: '401', body: JSON.generate({ 'message' => 'bad token' }))
      allow(err).to receive(:is_a?).with(Net::HTTPSuccess).and_return(false)

      http = instance_double(Net::HTTP)
      allow(Net::HTTP).to receive(:new).and_return(http)
      allow(http).to receive(:use_ssl=)
      allow(http).to receive(:open_timeout=)
      allow(http).to receive(:read_timeout=)
      allow(http).to receive(:request).and_return(err)

      expect { client.list_collections }
        .to raise_error(Woods::Error, /401/)
    end

    it 'surfaces title/detail from RFC7807-style error bodies' do
      # The live Unblocked API returns { status, title, detail } — not message/error.
      err = instance_double(Net::HTTPResponse, code: '400',
                                               body: JSON.generate({ 'status' => 400, 'title' => 'Bad Request',
                                                                     'detail' => 'Invalid request body' }))
      allow(err).to receive(:is_a?).with(Net::HTTPSuccess).and_return(false)

      http = instance_double(Net::HTTP)
      allow(Net::HTTP).to receive(:new).and_return(http)
      allow(http).to receive(:use_ssl=)
      allow(http).to receive(:open_timeout=)
      allow(http).to receive(:read_timeout=)
      allow(http).to receive(:request).and_return(err)

      expect { client.list_collections }
        .to raise_error(Woods::Error, /Invalid request body/)
    end

    it 'handles a malformed JSON response body without crashing' do
      err = instance_double(Net::HTTPResponse, code: '500', body: 'internal error html')
      allow(err).to receive(:is_a?).with(Net::HTTPSuccess).and_return(false)

      http = instance_double(Net::HTTP)
      allow(Net::HTTP).to receive(:new).and_return(http)
      allow(http).to receive(:use_ssl=)
      allow(http).to receive(:open_timeout=)
      allow(http).to receive(:read_timeout=)
      allow(http).to receive(:request).and_return(err)

      expect { client.list_collections }
        .to raise_error(Woods::Error, /500/)
    end
  end

  describe '#create_collection' do
    it 'omits icon_url when nil' do
      success = instance_double(Net::HTTPSuccess, code: '200', body: JSON.generate({ 'id' => 'c' }))
      allow(success).to receive(:is_a?).with(Net::HTTPSuccess).and_return(true)

      http = instance_double(Net::HTTP)
      allow(Net::HTTP).to receive(:new).and_return(http)
      allow(http).to receive(:use_ssl=)
      allow(http).to receive(:open_timeout=)
      allow(http).to receive(:read_timeout=)
      captured = nil
      allow(http).to receive(:request) do |req|
        captured = req
        success
      end

      client.create_collection(name: 'Woods', description: 'an index')
      body = JSON.parse(captured.body)
      expect(body).not_to have_key('iconUrl')
    end
  end

  # Helper: stub Net::HTTP so successive requests return the given response bodies
  # (as JSON), capturing each request path. Mirrors the per-example stubbing the
  # other specs use, factored out for the paginated list cases.
  def stub_http_sequence(*bodies) # rubocop:disable Metrics/AbcSize
    responses = bodies.map do |body|
      resp = instance_double(Net::HTTPSuccess, code: '200', body: JSON.generate(body))
      allow(resp).to receive(:is_a?).with(Net::HTTPSuccess).and_return(true)
      resp
    end
    http = instance_double(Net::HTTP)
    allow(Net::HTTP).to receive(:new).and_return(http)
    allow(http).to receive(:use_ssl=)
    allow(http).to receive(:open_timeout=)
    allow(http).to receive(:read_timeout=)
    paths = []
    allow(http).to receive(:request) do |req|
      paths << req.path
      responses.shift
    end
    paths
  end

  describe '#list_documents' do
    it 'sends a GET to /documents with the limit and returns the array' do
      paths = stub_http_sequence([{ 'id' => 'd1', 'uri' => 'u1' }])

      result = client.list_documents(limit: 50)

      expect(result).to eq([{ 'id' => 'd1', 'uri' => 'u1' }])
      expect(paths.first).to include('documents')
      expect(paths.first).to include('limit=50')
    end

    it 'passes the after cursor when given' do
      paths = stub_http_sequence([])
      client.list_documents(after: 'cursor-abc')
      expect(paths.first).to include('after=cursor-abc')
    end
  end

  describe '#all_documents' do
    it 'pages via the after cursor until a short page and filters by collection' do
      page1 = (1..200).map { |i| { 'id' => "d#{i}", 'uri' => "u#{i}", 'collectionId' => 'col-1' } }
      page2 = [
        { 'id' => 'd201', 'uri' => 'u201', 'collectionId' => 'col-1' },
        { 'id' => 'd202', 'uri' => 'u202', 'collectionId' => 'other' }
      ]
      paths = stub_http_sequence(page1, page2)

      result = client.all_documents(collection_id: 'col-1')

      # 200 from page1 + 1 matching from page2; the 'other' collection is filtered out
      expect(result.size).to eq(201)
      expect(result.map { |d| d['collectionId'] }.uniq).to eq(['col-1'])
      # second request carried the last id of page1 as the cursor
      expect(paths.size).to eq(2)
      expect(paths.last).to include('after=d200')
    end

    it 'stops after a single short page' do
      paths = stub_http_sequence([{ 'id' => 'd1', 'uri' => 'u1', 'collectionId' => 'col-1' }])
      result = client.all_documents(collection_id: 'col-1')
      expect(result.size).to eq(1)
      expect(paths.size).to eq(1)
    end
  end

  describe '#delete_document' do
    it 'sends a DELETE to documents/<id>' do
      success = instance_double(Net::HTTPSuccess, code: '200', body: '')
      allow(success).to receive(:is_a?).with(Net::HTTPSuccess).and_return(true)

      http = instance_double(Net::HTTP)
      allow(Net::HTTP).to receive(:new).and_return(http)
      allow(http).to receive(:use_ssl=)
      allow(http).to receive(:open_timeout=)
      allow(http).to receive(:read_timeout=)
      captured_uri = nil
      allow(http).to receive(:request) do |req|
        captured_uri = req.path
        success
      end

      client.delete_document(document_id: 'doc-42')
      expect(captured_uri).to include('documents/doc-42')
    end
  end
end
