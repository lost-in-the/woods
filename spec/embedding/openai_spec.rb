# frozen_string_literal: true

require 'spec_helper'
require 'codebase_index'
require 'codebase_index/embedding/provider'
require 'codebase_index/embedding/openai'

RSpec.describe CodebaseIndex::Embedding::Provider::OpenAI do
  subject(:provider) { described_class.new(api_key: 'test-key') }

  let(:single_embedding) { [0.1, 0.2, 0.3, 0.4, 0.5] }
  let(:batch_embeddings) { [[0.1, 0.2, 0.3], [0.4, 0.5, 0.6]] }

  let(:single_response_body) do
    { 'data' => [{ 'embedding' => single_embedding, 'index' => 0 }] }.to_json
  end

  let(:batch_response_body) do
    {
      'data' => [
        { 'embedding' => batch_embeddings[1], 'index' => 1 },
        { 'embedding' => batch_embeddings[0], 'index' => 0 }
      ]
    }.to_json
  end

  let(:success_response) do
    instance_double(Net::HTTPSuccess, body: single_response_body)
  end

  let(:batch_success_response) do
    instance_double(Net::HTTPSuccess, body: batch_response_body)
  end

  let(:http_double) { instance_double(Net::HTTP) }

  before do
    allow(Net::HTTP).to receive(:new).and_return(http_double)
    allow(http_double).to receive(:use_ssl=)
    allow(http_double).to receive(:open_timeout=)
    allow(http_double).to receive(:read_timeout=)
    allow(http_double).to receive(:keep_alive_timeout=)
    allow(http_double).to receive(:start).and_return(http_double)
    allow(http_double).to receive(:started?).and_return(true)
    allow(success_response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(true)
    allow(batch_success_response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(true)
  end

  describe '#embed' do
    before { allow(http_double).to receive(:request).and_return(success_response) }

    it 'returns a vector array' do
      result = provider.embed('hello world')
      expect(result).to eq(single_embedding)
    end

    it 'sends the correct request body' do
      provider.embed('hello world')
      expect(http_double).to have_received(:request) do |req|
        body = JSON.parse(req.body)
        expect(body['model']).to eq('text-embedding-3-small')
        expect(body['input']).to eq('hello world')
      end
    end

    it 'sends the Authorization header' do
      provider.embed('hello world')
      expect(http_double).to have_received(:request) do |req|
        expect(req['Authorization']).to eq('Bearer test-key')
      end
    end

    it 'enables SSL on the HTTP connection' do
      provider.embed('hello world')
      expect(http_double).to have_received(:use_ssl=).with(true)
    end
  end

  describe '#embed_batch' do
    before { allow(http_double).to receive(:request).and_return(batch_success_response) }

    it 'returns an array of vectors sorted by index' do
      result = provider.embed_batch(%w[text1 text2])
      expect(result).to eq(batch_embeddings)
    end

    it 'sends all texts in a single request' do
      provider.embed_batch(%w[text1 text2])
      expect(http_double).to have_received(:request) do |req|
        body = JSON.parse(req.body)
        expect(body['input']).to eq(%w[text1 text2])
      end
    end
  end

  describe '#dimensions' do
    it 'returns known dimensions for text-embedding-3-small' do
      expect(provider.dimensions).to eq(1536)
    end

    it 'returns known dimensions for text-embedding-3-large' do
      large_provider = described_class.new(api_key: 'test-key', model: 'text-embedding-3-large')
      expect(large_provider.dimensions).to eq(3072)
    end

    it 'falls back to embed call for unknown models' do
      allow(http_double).to receive(:request).and_return(success_response)
      custom_provider = described_class.new(api_key: 'test-key', model: 'custom-model')
      expect(custom_provider.dimensions).to eq(5)
    end
  end

  describe '#model_name' do
    it 'returns the default model name' do
      expect(provider.model_name).to eq('text-embedding-3-small')
    end

    it 'returns a custom model name' do
      custom_provider = described_class.new(api_key: 'test-key', model: 'text-embedding-3-large')
      expect(custom_provider.model_name).to eq('text-embedding-3-large')
    end
  end

  describe 'HTTP timeout configuration' do
    before { allow(http_double).to receive(:request).and_return(success_response) }

    it 'sets open_timeout on the HTTP connection' do
      provider.embed('hello')
      expect(http_double).to have_received(:open_timeout=).with(10)
    end

    it 'sets read_timeout on the HTTP connection' do
      provider.embed('hello')
      expect(http_double).to have_received(:read_timeout=).with(30)
    end
  end

  describe 'error handling' do
    let(:error_429_response) do
      instance_double(Net::HTTPTooManyRequests, code: '429', body: 'rate limit exceeded')
    end

    let(:error_500_response) do
      instance_double(Net::HTTPInternalServerError, code: '500', body: 'internal server error')
    end

    before do
      allow(error_429_response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(false)
      allow(error_500_response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(false)
    end

    it 'raises CodebaseIndex::Error on 429 response' do
      allow(http_double).to receive(:request).and_return(error_429_response)
      expect { provider.embed('text') }.to raise_error(
        CodebaseIndex::Error, /OpenAI API error: 429 rate limit exceeded/
      )
    end

    it 'raises CodebaseIndex::Error on 500 response' do
      allow(http_double).to receive(:request).and_return(error_500_response)
      expect { provider.embed('text') }.to raise_error(
        CodebaseIndex::Error, /OpenAI API error: 500 internal server error/
      )
    end
  end

  describe 'connection retry' do
    it 'retries once on ECONNRESET' do
      allow(http_double).to receive(:request)
        .and_raise(Errno::ECONNRESET)
      retry_http = instance_double(Net::HTTP)
      allow(Net::HTTP).to receive(:new).and_return(http_double, retry_http)
      allow(retry_http).to receive(:use_ssl=)
      allow(retry_http).to receive(:open_timeout=)
      allow(retry_http).to receive(:read_timeout=)
      allow(retry_http).to receive(:keep_alive_timeout=)
      allow(retry_http).to receive(:start).and_return(retry_http)
      allow(retry_http).to receive(:started?).and_return(true)
      allow(retry_http).to receive(:request).and_return(success_response)

      result = provider.embed('hello')
      expect(result).to eq(single_embedding)
    end

    it 'propagates error when retry also fails' do
      allow(http_double).to receive(:request)
        .and_raise(Errno::ECONNRESET)
      retry_http = instance_double(Net::HTTP)
      allow(Net::HTTP).to receive(:new).and_return(http_double, retry_http)
      allow(retry_http).to receive(:use_ssl=)
      allow(retry_http).to receive(:open_timeout=)
      allow(retry_http).to receive(:read_timeout=)
      allow(retry_http).to receive(:keep_alive_timeout=)
      allow(retry_http).to receive(:start).and_return(retry_http)
      allow(retry_http).to receive(:started?).and_return(true)
      allow(retry_http).to receive(:request).and_raise(Errno::ECONNRESET)

      expect { provider.embed('hello') }.to raise_error(Errno::ECONNRESET)
    end
  end

  describe 'custom configuration' do
    subject(:custom_provider) do
      described_class.new(api_key: 'custom-key', model: 'text-embedding-3-large')
    end

    before { allow(http_double).to receive(:request).and_return(success_response) }

    it 'uses the custom model name' do
      expect(custom_provider.model_name).to eq('text-embedding-3-large')
    end

    it 'connects to the OpenAI endpoint' do
      custom_provider.embed('text')
      expect(Net::HTTP).to have_received(:new).with('api.openai.com', 443)
    end

    it 'sends the custom model in requests' do
      custom_provider.embed('text')
      expect(http_double).to have_received(:request) do |req|
        body = JSON.parse(req.body)
        expect(body['model']).to eq('text-embedding-3-large')
      end
    end

    it 'uses the custom API key in Authorization header' do
      custom_provider.embed('text')
      expect(http_double).to have_received(:request) do |req|
        expect(req['Authorization']).to eq('Bearer custom-key')
      end
    end
  end
end
