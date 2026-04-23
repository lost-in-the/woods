# frozen_string_literal: true

require 'spec_helper'
require 'woods'
require 'woods/embedding/provider'

RSpec.describe Woods::Embedding::Provider do
  describe Woods::Embedding::Provider::Interface do
    let(:dummy_class) do
      Class.new { include Woods::Embedding::Provider::Interface }
    end
    let(:instance) { dummy_class.new }

    it 'raises NotImplementedError for #embed' do
      expect { instance.embed('text') }.to raise_error(NotImplementedError)
    end

    it 'raises NotImplementedError for #embed_batch' do
      expect { instance.embed_batch(%w[a b]) }.to raise_error(NotImplementedError)
    end

    it 'raises NotImplementedError for #dimensions' do
      expect { instance.dimensions }.to raise_error(NotImplementedError)
    end

    it 'raises NotImplementedError for #model_name' do
      expect { instance.model_name }.to raise_error(NotImplementedError)
    end
  end

  describe Woods::Embedding::Provider::Ollama do
    subject(:provider) { described_class.new }

    let(:single_embedding) { [0.1, 0.2, 0.3, 0.4, 0.5] }
    let(:batch_embeddings) { [[0.1, 0.2, 0.3], [0.4, 0.5, 0.6]] }

    let(:single_response_body) { { 'embeddings' => [single_embedding] }.to_json }
    let(:batch_response_body) { { 'embeddings' => batch_embeddings }.to_json }

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
      allow(http_double).to receive(:start)
      allow(http_double).to receive(:started?).and_return(false, true)
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
          expect(body['model']).to eq('nomic-embed-text')
          expect(body['input']).to eq('hello world')
        end
      end
    end

    describe '#embed_batch' do
      before { allow(http_double).to receive(:request).and_return(batch_success_response) }

      it 'returns an array of vectors' do
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
      before { allow(http_double).to receive(:request).and_return(success_response) }

      it 'returns the vector length' do
        expect(provider.dimensions).to eq(5)
      end

      it 'caches the result' do
        provider.dimensions
        provider.dimensions
        expect(http_double).to have_received(:request).once
      end
    end

    describe '#model_name' do
      it 'returns the default model name' do
        expect(provider.model_name).to eq('nomic-embed-text')
      end
    end

    describe '#max_input_tokens' do
      it 'tracks an explicit num_ctx override' do
        expect(described_class.new(num_ctx: 4096).max_input_tokens).to eq(4096)
      end

      it 'falls back to the registry for the configured model' do
        expect(described_class.new(model: 'bge-m3').max_input_tokens).to eq(8192)
      end

      it 'uses the conservative fallback for unknown models' do
        expect(described_class.new(model: 'mystery-embed').max_input_tokens).to eq(2048)
      end
    end

    describe 'error handling' do
      let(:error_response) do
        instance_double(Net::HTTPInternalServerError, code: '500', body: 'model not found')
      end

      before do
        allow(error_response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(false)
        allow(http_double).to receive(:request).and_return(error_response)
      end

      it 'raises Woods::Error on non-200 response' do
        expect { provider.embed('text') }.to raise_error(
          Woods::Error, /Ollama API error: 500 model not found/
        )
      end
    end

    describe 'custom configuration' do
      subject(:custom_provider) do
        described_class.new(model: 'mxbai-embed-large', host: 'http://gpu-server:11434')
      end

      before { allow(http_double).to receive(:request).and_return(success_response) }

      it 'uses the custom model name' do
        expect(custom_provider.model_name).to eq('mxbai-embed-large')
      end

      it 'connects to the custom host' do
        custom_provider.embed('text')
        expect(Net::HTTP).to have_received(:new).with('gpu-server', 11_434)
      end

      it 'sends the custom model in requests' do
        custom_provider.embed('text')
        expect(http_double).to have_received(:request) do |req|
          body = JSON.parse(req.body)
          expect(body['model']).to eq('mxbai-embed-large')
        end
      end
    end

    describe 'context window (num_ctx)' do
      before { allow(http_double).to receive(:request).and_return(success_response) }

      # Regression — Ollama's `/api/embed` enforces the model's native context
      # length regardless of `options.num_ctx` (see ollama/ollama#14186). We
      # advertise the native ceiling so the chunker sizes inputs correctly —
      # for nomic-embed-text that's 2048.
      it 'defaults to the native context for nomic-embed-text' do
        provider.embed('text')
        expect(http_double).to have_received(:request) do |req|
          body = JSON.parse(req.body)
          expect(body.dig('options', 'num_ctx')).to eq(2048)
        end
      end

      it 'auto-selects num_ctx from the registry for known models' do
        described_class.new(model: 'bge-m3').embed('text')
        expect(http_double).to have_received(:request) do |req|
          body = JSON.parse(req.body)
          expect(body.dig('options', 'num_ctx')).to eq(8192)
        end
      end

      it 'includes the registry num_ctx in batch requests' do
        allow(http_double).to receive(:request).and_return(batch_success_response)
        described_class.new(model: 'bge-m3').embed_batch(%w[a b])
        expect(http_double).to have_received(:request) do |req|
          body = JSON.parse(req.body)
          expect(body.dig('options', 'num_ctx')).to eq(8192)
        end
      end

      it 'honours an explicit num_ctx override' do
        described_class.new(num_ctx: 4096).embed('text')
        expect(http_double).to have_received(:request) do |req|
          body = JSON.parse(req.body)
          expect(body.dig('options', 'num_ctx')).to eq(4096)
        end
      end

      it 'falls back to the conservative default for unknown models' do
        described_class.new(model: 'mystery-embed').embed('text')
        expect(http_double).to have_received(:request) do |req|
          body = JSON.parse(req.body)
          expect(body.dig('options', 'num_ctx')).to eq(2048)
        end
      end
    end
  end
end
