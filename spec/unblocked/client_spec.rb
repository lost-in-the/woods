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
