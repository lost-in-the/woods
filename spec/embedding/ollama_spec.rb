# frozen_string_literal: true

require 'spec_helper'
require 'woods'
require 'woods/embedding/provider'

RSpec.describe Woods::Embedding::Provider::Ollama do
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
    allow(http_double).to receive(:start).and_return(http_double)
    allow(http_double).to receive(:started?).and_return(false, true)
    allow(success_response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(true)
    allow(batch_success_response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(true)
  end

  describe '#embed' do
    before { allow(http_double).to receive(:request).and_return(success_response) }

    it 'returns a vector array' do
      expect(provider.embed('hello world')).to eq(single_embedding)
    end

    it 'sends the correct request body' do
      provider.embed('hello world')
      expect(http_double).to have_received(:request) do |req|
        body = JSON.parse(req.body)
        expect(body['model']).to eq('nomic-embed-text')
        expect(body['input']).to eq('hello world')
      end
    end

    it 'sends a Content-Type: application/json header' do
      provider.embed('hello world')
      expect(http_double).to have_received(:request) do |req|
        expect(req['Content-Type']).to eq('application/json')
      end
    end

    it 'rejects nil input with ArgumentError' do
      expect { provider.embed(nil) }.to raise_error(ArgumentError, /non-empty string/)
    end

    it 'rejects empty input with ArgumentError' do
      expect { provider.embed('') }.to raise_error(ArgumentError, /non-empty string/)
    end

    it 'rejects whitespace-only input with ArgumentError' do
      expect { provider.embed("   \n\t  ") }.to raise_error(ArgumentError, /non-empty string/)
    end
  end

  describe '#embed_batch' do
    before { allow(http_double).to receive(:request).and_return(batch_success_response) }

    it 'returns an array of vectors' do
      expect(provider.embed_batch(%w[text1 text2])).to eq(batch_embeddings)
    end

    it 'sends all texts in a single request' do
      provider.embed_batch(%w[text1 text2])
      expect(http_double).to have_received(:request) do |req|
        body = JSON.parse(req.body)
        expect(body['input']).to eq(%w[text1 text2])
      end
    end

    it 'rejects a nil array with ArgumentError' do
      expect { provider.embed_batch(nil) }.to raise_error(ArgumentError, /non-empty array/)
    end

    it 'rejects an empty array with ArgumentError' do
      expect { provider.embed_batch([]) }.to raise_error(ArgumentError, /non-empty array/)
    end

    it 'rejects an array containing nil entries with ArgumentError' do
      expect { provider.embed_batch(['ok', nil]) }.to raise_error(ArgumentError, %r{nil/empty entries})
    end

    it 'rejects an array containing empty entries with ArgumentError' do
      expect { provider.embed_batch(['ok', '']) }.to raise_error(ArgumentError, %r{nil/empty entries})
    end

    it 'rejects an array containing whitespace-only entries with ArgumentError' do
      expect { provider.embed_batch(['ok', "  \n  "]) }.to raise_error(ArgumentError, %r{nil/empty entries})
    end
  end

  describe 'response validation (silent index corruption)' do
    it 'raises a typed error when embed gets an empty embeddings array' do
      empty_response = instance_double(Net::HTTPSuccess, body: { 'embeddings' => [] }.to_json)
      allow(empty_response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(true)
      allow(http_double).to receive(:request).and_return(empty_response)

      expect { provider.embed('hello world') }
        .to raise_error(Woods::Embedding::Provider::InvalidEmbeddingResponse)
    end

    it 'raises a typed error when embed_batch gets fewer vectors than texts requested' do
      short_response = instance_double(Net::HTTPSuccess, body: { 'embeddings' => [single_embedding] }.to_json)
      allow(short_response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(true)
      allow(http_double).to receive(:request).and_return(short_response)

      expect { provider.embed_batch(%w[text1 text2]) }
        .to raise_error(Woods::Embedding::Provider::InvalidEmbeddingResponse)
    end

    it 'raises a typed error when a returned vector contains a null entry' do
      # See the OpenAI spec for why null (not NaN/Infinity) is what's used
      # to exercise this over-the-wire — NaN can't round-trip through JSON.
      null_entry_response = instance_double(Net::HTTPSuccess, body: { 'embeddings' => [[0.1, nil, 0.3]] }.to_json)
      allow(null_entry_response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(true)
      allow(http_double).to receive(:request).and_return(null_entry_response)

      expect { provider.embed('hello world') }
        .to raise_error(Woods::Embedding::Provider::InvalidEmbeddingResponse)
    end

    it 'raises a typed error when batch vectors have inconsistent dimensions' do
      drift_response = instance_double(
        Net::HTTPSuccess,
        body: { 'embeddings' => [[0.1, 0.2, 0.3], [0.4, 0.5]] }.to_json
      )
      allow(drift_response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(true)
      allow(http_double).to receive(:request).and_return(drift_response)

      expect { provider.embed_batch(%w[text1 text2]) }
        .to raise_error(Woods::Embedding::Provider::InvalidEmbeddingResponse, /dimension/i)
    end

    it 'does not raise for a well-formed batch response' do
      allow(http_double).to receive(:request).and_return(batch_success_response)
      expect { provider.embed_batch(%w[text1 text2]) }.not_to raise_error
    end
  end

  describe '#dimensions' do
    before { allow(http_double).to receive(:request).and_return(success_response) }

    it 'returns the vector length from a probe embedding' do
      expect(provider.dimensions).to eq(5)
    end

    it 'caches the result across calls' do
      provider.dimensions
      provider.dimensions
      expect(http_double).to have_received(:request).once
    end

    it 'works for unknown models by probing the live response shape' do
      custom = described_class.new(model: 'mystery-embed')
      expect(custom.dimensions).to eq(5)
    end

    it 'returns an explicitly requested dimension without probing the API' do
      custom = described_class.new(dimensions: 256)

      expect(custom.dimensions).to eq(256)
      expect(http_double).not_to have_received(:request)
    end
  end

  describe '#model_name' do
    it 'returns the default model name' do
      expect(provider.model_name).to eq('nomic-embed-text')
    end

    it 'returns a custom model name' do
      custom = described_class.new(model: 'bge-m3')
      expect(custom.model_name).to eq('bge-m3')
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

    # Regression for the silent-chunk-drop bug fixed alongside the
    # build_chunker guard. all-minilm has a 512-token context (NOT
    # the 384 embedding dimension and NOT the 256 some sources cite);
    # a 256-token budget would push max_chars negative and cause
    # SemanticChunker to drop every chunk silently.
    it 'reports 512 for all-minilm (the model context, not the dimension)' do
      expect(described_class.new(model: 'all-minilm').max_input_tokens).to eq(512)
    end
  end

  describe 'HTTP timeout configuration' do
    before { allow(http_double).to receive(:request).and_return(success_response) }

    it 'sets open_timeout to 10 seconds on the HTTP connection' do
      provider.embed('hello')
      expect(http_double).to have_received(:open_timeout=).with(10)
    end

    it 'sets read_timeout to the default 120 seconds on the HTTP connection' do
      provider.embed('hello')
      expect(http_double).to have_received(:read_timeout=).with(120)
    end

    it 'sets keep_alive_timeout to 30 seconds on the HTTP connection' do
      provider.embed('hello')
      expect(http_double).to have_received(:keep_alive_timeout=).with(30)
    end

    it 'honours a custom read_timeout' do
      described_class.new(read_timeout: 300).embed('hello')
      expect(http_double).to have_received(:read_timeout=).with(300)
    end
  end

  describe 'SSL configuration' do
    before { allow(http_double).to receive(:request).and_return(success_response) }

    it 'leaves SSL disabled for an http:// host' do
      provider.embed('hello')
      expect(http_double).to have_received(:use_ssl=).with(false)
    end

    it 'enables SSL for an https:// host' do
      described_class.new(host: 'https://ollama.example.com').embed('hello')
      expect(http_double).to have_received(:use_ssl=).with(true)
    end
  end

  describe 'error handling' do
    let(:error_500_response) do
      instance_double(Net::HTTPInternalServerError, code: '500', body: 'model not found')
    end

    let(:error_404_response) do
      instance_double(Net::HTTPNotFound, code: '404', body: 'not found')
    end

    before do
      allow(error_500_response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(false)
      allow(error_500_response).to receive(:[]).with('Retry-After').and_return(nil)
      allow(error_404_response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(false)
      allow(error_404_response).to receive(:[]).with('Retry-After').and_return(nil)
    end

    it 'raises Woods::Error on 500 response' do
      allow(http_double).to receive(:request).and_return(error_500_response)
      expect { provider.embed('text') }.to raise_error(
        Woods::Error, /Ollama API error: 500 model not found/
      )
    end

    it 'raises Woods::Error on 404 response' do
      allow(http_double).to receive(:request).and_return(error_404_response)
      expect { provider.embed('text') }.to raise_error(
        Woods::Error, /Ollama API error: 404 not found/
      )
    end

    # #188 — the error must carry the HTTP status and Retry-After header so
    # RetryableProvider can classify it and honor the server's back-off.
    it 'attaches http_status and Retry-After to a 429 error' do
      throttled = instance_double(Net::HTTPTooManyRequests, code: '429', body: 'slow down')
      allow(throttled).to receive(:is_a?).with(Net::HTTPSuccess).and_return(false)
      allow(throttled).to receive(:[]).with('Retry-After').and_return('3')
      allow(http_double).to receive(:request).and_return(throttled)

      expect { provider.embed('text') }
        .to raise_error(Woods::Embedding::Provider::RequestError) do |error|
          expect(error.http_status).to eq(429)
          expect(error.retry_after).to eq('3')
        end
    end

    it 'attaches http_status (and nil retry_after) to a 500 error' do
      allow(http_double).to receive(:request).and_return(error_500_response)

      expect { provider.embed('text') }
        .to raise_error(Woods::Embedding::Provider::RequestError) do |error|
          expect(error.http_status).to eq(500)
          expect(error.retry_after).to be_nil
        end
    end

    it 'truncates oversized error response bodies to keep logs bounded' do
      huge_body = 'x' * 5_000
      huge_response = instance_double(Net::HTTPBadGateway, code: '502', body: huge_body)
      allow(huge_response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(false)
      allow(huge_response).to receive(:[]).with('Retry-After').and_return(nil)
      allow(http_double).to receive(:request).and_return(huge_response)

      expect { provider.embed('text') }.to raise_error(Woods::Error) do |error|
        expect(error.message).to include('... [truncated]')
        expect(error.message.length).to be < huge_body.length
      end
    end

    it 'propagates JSON::ParserError on malformed success bodies' do
      malformed = instance_double(Net::HTTPSuccess, body: 'not-json{{{')
      allow(malformed).to receive(:is_a?).with(Net::HTTPSuccess).and_return(true)
      allow(http_double).to receive(:request).and_return(malformed)

      expect { provider.embed('text') }.to raise_error(JSON::ParserError)
    end
  end

  describe 'connection retry' do
    let(:retry_http) { instance_double(Net::HTTP) }

    before do
      allow(Net::HTTP).to receive(:new).and_return(http_double, retry_http)
      allow(retry_http).to receive(:use_ssl=)
      allow(retry_http).to receive(:open_timeout=)
      allow(retry_http).to receive(:read_timeout=)
      allow(retry_http).to receive(:keep_alive_timeout=)
      allow(retry_http).to receive(:start).and_return(retry_http)
      allow(retry_http).to receive(:started?).and_return(true)
    end

    it 'retries once on Errno::ECONNRESET and returns the embedding' do
      allow(http_double).to receive(:request).and_raise(Errno::ECONNRESET)
      allow(retry_http).to receive(:request).and_return(success_response)

      expect(provider.embed('hello')).to eq(single_embedding)
    end

    it 'retries once on Net::OpenTimeout and returns the embedding' do
      allow(http_double).to receive(:request).and_raise(Net::OpenTimeout)
      allow(retry_http).to receive(:request).and_return(success_response)

      expect(provider.embed('hello')).to eq(single_embedding)
    end

    it 'retries once on Net::ReadTimeout and returns the embedding' do
      allow(http_double).to receive(:request).and_raise(Net::ReadTimeout)
      allow(retry_http).to receive(:request).and_return(success_response)

      expect(provider.embed('hello')).to eq(single_embedding)
    end

    it 'retries once on IOError and returns the embedding' do
      allow(http_double).to receive(:request).and_raise(IOError)
      allow(retry_http).to receive(:request).and_return(success_response)

      expect(provider.embed('hello')).to eq(single_embedding)
    end

    it 'wraps a second-attempt failure in Woods::Error with retry-failed context' do
      allow(http_double).to receive(:request).and_raise(Errno::ECONNRESET)
      allow(retry_http).to receive(:request).and_raise(Errno::ECONNRESET, 'connection reset by peer')

      expect { provider.embed('hello') }.to raise_error(
        Woods::Error, /Ollama API error \(retry failed\): .*connection reset by peer/
      )
    end

    it 'raises Woods::Error if the retry response is itself non-success' do
      allow(http_double).to receive(:request).and_raise(Net::ReadTimeout)
      retry_error_response = instance_double(Net::HTTPInternalServerError, code: '500', body: 'still down')
      allow(retry_error_response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(false)
      allow(retry_error_response).to receive(:[]).with('Retry-After').and_return(nil)
      allow(retry_http).to receive(:request).and_return(retry_error_response)

      expect { provider.embed('hello') }.to raise_error(
        Woods::Error, /Ollama API error: 500 still down/
      )
    end

    it 'discards the original HTTP client and issues the retry on the fresh one' do
      allow(http_double).to receive(:request).and_raise(Errno::ECONNRESET)
      allow(retry_http).to receive(:request).and_return(success_response)

      provider.embed('hello')

      expect(http_double).to have_received(:request).once
      expect(retry_http).to have_received(:request).once
      expect(Net::HTTP).to have_received(:new).twice
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

    it 'sends explicitly configured dimensions in requests' do
      described_class.new(dimensions: 256).embed('text')

      expect(http_double).to have_received(:request) do |request|
        expect(JSON.parse(request.body)['dimensions']).to eq(256)
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
