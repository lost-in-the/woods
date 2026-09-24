# frozen_string_literal: true

require 'spec_helper'
require 'woods'
require 'woods/builder'
require 'woods/mcp/config_resolver'
require 'woods/cache/cache_middleware'
require 'woods/cache/cache_store'

RSpec.describe 'Embedding configuration consistency' do
  let(:cache) { Woods::Cache::InMemory.new }

  def openai(options = {})
    Woods::Embedding::Provider::OpenAI.new(api_key: 'synthetic-key', **options)
  end

  def cached(provider)
    Woods::Cache::CachedEmbeddingProvider.new(provider: provider, cache_store: cache)
  end

  def resolved_provider(model:, dimension:, **extra)
    restore_snapshot(
      'schema_version' => 1,
      'embedding_provider' => {
        'class' => 'Woods::Embedding::Provider::OpenAI', 'model' => model, 'dimension' => dimension
      }.merge(extra.transform_keys(&:to_s))
    )
  end

  def restore_snapshot(snapshot)
    stored = Woods::ResolvedConfig.from_hash(snapshot)
    artifact = double('Artifact', output_dir: Pathname('/synthetic'), config_path: '/synthetic/woods.json')
    config, = Woods::MCP::ConfigResolver.resolve(
      Woods::Configuration.new, artifact: artifact, stored_config: stored,
                                env: { 'OPENAI_API_KEY' => 'synthetic-key' }
    )
    Woods::Builder.new(config).build_embedding_provider
  end

  def openai_response(width, count = 1)
    { 'data' => Array.new(count) { |i| { 'index' => i, 'embedding' => Array.new(width, 0.5) } } }
  end

  it 'restores a fixed-width ada snapshot without requesting dimensions' do
    provider = resolved_provider(model: 'text-embedding-ada-002', dimension: 1536)
    allow(provider).to receive(:post_request).and_return(openai_response(1536))

    expect(provider.dimensions).to eq(1536)
    provider.embed('query')
    expect(provider).to have_received(:post_request).with(model: 'text-embedding-ada-002', input: 'query')
  end

  it 'accepts an explicit matching ada width without sending the unsupported option' do
    provider = openai(model: 'text-embedding-ada-002', dimensions: 1536)
    allow(provider).to receive(:post_request).and_return(openai_response(1536))

    provider.embed('query')
    expect(provider).to have_received(:post_request).with(model: 'text-embedding-ada-002', input: 'query')
  end

  it 'refuses an impossible explicit ada reduction before any request' do
    expect { openai(model: 'text-embedding-ada-002', dimensions: 256) }
      .to raise_error(ArgumentError, /1536/)
  end

  it 'refuses a stored width incompatible with fixed-width ada' do
    expect { resolved_provider(model: 'text-embedding-ada-002', dimension: 256) }
      .to raise_error(ArgumentError, /1536/)
  end

  it 'retains the supported reduced width of a legacy OpenAI v3 snapshot' do
    provider = resolved_provider(model: 'text-embedding-3-small', dimension: 3)
    allow(provider).to receive(:post_request).and_return(openai_response(3))

    provider.embed('query')
    expect(provider).to have_received(:post_request).with(
      model: 'text-embedding-3-small', input: 'query', dimensions: 3
    )
  end

  it 'does not infer a dimensions request for an unknown model from its observed width' do
    provider = resolved_provider(model: 'custom-embedding-model', dimension: 3)
    allow(provider).to receive(:post_request).and_return(openai_response(3))

    provider.embed('query')
    expect(provider).to have_received(:post_request).with(model: 'custom-embedding-model', input: 'query')
  end

  it 'records the explicit request width separately from the observed snapshot width' do
    config = Woods::Configuration.new
    config.embedding_provider = :openai
    config.embedding_options = { api_key: 'synthetic-key', dimensions: 3 }
    provider = Woods::Builder.new(config).build_embedding_provider
    snapshot = Woods::ResolvedConfig.from_configuration(config, provider: provider).to_snapshot_json

    expect(snapshot.fetch('embedding_provider')).to include('dimension' => 3, 'requested_dimensions' => 3)
    expect(Woods::ResolvedConfig.from_hash(snapshot).embedding_provider[:requested_dimensions]).to eq(3)
    restored = resolved_provider(model: 'text-embedding-3-small', dimension: 3, requested_dimensions: 3)
    allow(restored).to receive(:post_request).and_return(openai_response(3))
    restored.embed('query')
    expect(restored).to have_received(:post_request).with(
      model: 'text-embedding-3-small', input: 'query', dimensions: 3
    )
  end

  it 'refuses contradictory stored requested and observed widths' do
    expect { resolved_provider(model: 'text-embedding-3-small', dimension: 3, requested_dimensions: 2) }
      .to raise_error(ArgumentError, /must match/)
  end

  it 'does not reinterpret an explicitly absent request width in a new snapshot' do
    expect { resolved_provider(model: 'text-embedding-3-small', dimension: 3, requested_dimensions: nil) }
      .to raise_error(ArgumentError, /set dimensions explicitly/)
  end

  it 'records an absent request width so a new snapshot is distinguishable from a legacy one' do
    config = Woods::Configuration.new
    config.embedding_provider = :ollama
    config.embedding_options = { expected_dimensions: 3 }
    provider = Woods::Builder.new(config).build_embedding_provider
    snapshot = Woods::ResolvedConfig.from_configuration(config, provider: provider).to_snapshot_json

    expect(snapshot.fetch('embedding_provider')).to include('dimension' => 3, 'requested_dimensions' => nil)
    expect(Woods::ResolvedConfig.from_hash(snapshot).embedding_provider).to have_key(:requested_dimensions)
  end

  it 'preserves the direct legacy singular dimension request alias' do
    config = Woods::Configuration.new
    config.embedding_provider = :openai
    config.embedding_options = { api_key: 'synthetic-key', dimension: 3 }
    provider = Woods::Builder.new(config).build_embedding_provider
    allow(provider).to receive(:post_request).and_return(openai_response(3))

    provider.embed('query')
    expect(provider).to have_received(:post_request).with(
      model: 'text-embedding-3-small', input: 'query', dimensions: 3
    )
  end

  it 'captures and restores an injected provider through the supported retry and cache wrappers' do
    config = Woods::Configuration.new
    config.embedding_provider = openai(dimensions: 3)
    config.embedding_options = {}
    retrying = Woods::Builder.new(config).build_resilient_embedding_provider
    wrapped = cached(retrying)
    expect(wrapped.requested_dimensions).to eq(3)
    expect(wrapped.configured_dimensions).to eq(3)
    expect(wrapped.cache_identity).to eq(config.embedding_provider.cache_identity)
    snapshot = Woods::ResolvedConfig.from_configuration(config, provider: wrapped).to_snapshot_json
    expect(snapshot.fetch('embedding_provider')).to include(
      'class' => 'Woods::Embedding::Provider::OpenAI', 'dimension' => 3, 'requested_dimensions' => 3
    )
    config.embedding_provider = wrapped
    expect(Woods::ResolvedConfig.from_configuration(config, provider: wrapped).embedding_provider[:class])
      .to eq('Woods::Embedding::Provider::OpenAI')
    restored = restore_snapshot(snapshot)
    allow(restored).to receive(:post_request).and_return(openai_response(3))

    restored.embed('query')
    expect(restored).to have_received(:post_request).with(
      model: 'text-embedding-3-small', input: 'query', dimensions: 3
    )
  end

  it 'keeps an observed Ollama width out of later request bodies' do
    provider = Woods::Embedding::Provider::Ollama.new
    allow(provider).to receive(:post_request).and_return('embeddings' => [Array.new(3, 0.5)])

    expect(provider.dimensions).to eq(3)
    provider.embed('query')
    expect(provider).to have_received(:post_request).with(
      model: 'nomic-embed-text', input: 'query', truncate: false, options: { num_ctx: 2048 }
    )
  end

  %i[openai ollama].each do |family|
    %i[embed embed_batch].each do |operation|
      it "refuses #{family} #{operation} responses with the wrong requested width" do
        provider = family == :openai ? openai(dimensions: 3) : Woods::Embedding::Provider::Ollama.new(dimensions: 3)
        response = family == :openai ? openai_response(2) : { 'embeddings' => [[0.1, 0.2]] }
        allow(provider).to receive(:post_request).and_return(response)

        expect { provider.public_send(operation, operation == :embed ? 'query' : ['query']) }
          .to raise_error(Woods::Embedding::Provider::InvalidEmbeddingResponse, /dimension/)
      end
    end
  end

  it 'isolates same-model fake providers with different configured widths' do
    cached(Woods::Embedding::Provider::Fake.new(dims: 2)).embed('same query')
    provider = Woods::Embedding::Provider::Fake.new(dims: 3)

    expect(cached(provider).embed('same query').size).to eq(3)
    expect(provider.calls).to eq([['same query']])
  end

  it 'isolates the same model and width on different Ollama endpoints through retry wrappers' do
    first = Woods::Embedding::Provider::Ollama.new(host: 'http://first.test', dimensions: 2)
    second = Woods::Embedding::Provider::Ollama.new(host: 'http://second.test', dimensions: 2)
    allow(first).to receive(:embed).and_return([0.1, 0.2])
    allow(second).to receive(:embed).and_return([0.8, 0.9])
    cached(Woods::Resilience::RetryableProvider.new(provider: first)).embed('same query')

    expect(cached(Woods::Resilience::RetryableProvider.new(provider: second)).embed('same query')).to eq([0.8, 0.9])
  end

  it 'shares identical provider configurations without probing dimensions during an outage' do
    first = openai(dimensions: 2)
    allow(first).to receive(:embed).and_return([0.1, 0.2])
    cached(first).embed('same query')
    second = openai(dimensions: 2)
    expect(second).not_to receive(:dimensions)
    expect(second).not_to receive(:embed)

    expect(cached(second).embed('same query')).to eq([0.1, 0.2])
  end

  it 'keeps an unknown Ollama model cache identity stable after observing its width' do
    provider = Woods::Embedding::Provider::Ollama.new(model: 'custom-model')
    allow(provider).to receive(:post_request).and_return('embeddings' => [[0.1, 0.2]])
    cached(provider).embed('same query')
    provider.dimensions
    offline = Woods::Embedding::Provider::Ollama.new(model: 'custom-model')
    expect(offline).not_to receive(:dimensions)
    expect(offline).not_to receive(:embed)

    expect(cached(offline).embed_batch(['same query'])).to eq([[0.1, 0.2]])
  end

  it 'isolates different provider families even with the same model name and width' do
    first = Woods::Embedding::Provider::Fake.new(model: 'shared-model', dims: 2)
    cached(first).embed('same query')
    second = Woods::Embedding::Provider::Ollama.new(model: 'shared-model', dimensions: 2)
    allow(second).to receive(:embed).and_return([0.8, 0.9])

    expect(cached(second).embed('same query')).to eq([0.8, 0.9])
  end

  it 'isolates custom provider instances that do not declare a stable cache identity' do
    first = double('CustomProvider', model_name: 'shared-model', embed: [0.1, 0.2])
    second = double('CustomProvider', model_name: 'shared-model', embed: [0.8, 0.9])
    cached(first).embed('same query')

    expect(cached(second).embed('same query')).to eq([0.8, 0.9])
  end

  it 'never includes endpoint credentials or API keys in backend keys' do
    provider = Woods::Embedding::Provider::Ollama.new(host: 'http://user:synthetic-password@endpoint.test',
                                                      dimensions: 2)
    allow(provider).to receive(:embed).and_return([0.1, 0.2])
    allow(cache).to receive(:write).and_call_original
    cached(provider).embed('query')
    second = openai(dimensions: 2)
    allow(second).to receive(:embed).and_return([0.1, 0.2])
    cached(second).embed('query')

    expect(cache).to have_received(:write).twice do |key, _value, **_options|
      expect(key).not_to include('synthetic-password', 'synthetic-key', 'endpoint.test')
    end
  end

  it 'rejects inconsistent widths in a batch of cached vectors without probing' do
    provider = Woods::Embedding::Provider::Ollama.new
    allow(cache).to receive(:read).and_return([0.1, 0.2], [0.3])
    expect(provider).not_to receive(:embed_batch)
    expect(provider).not_to receive(:dimensions)

    expect { cached(provider).embed_batch(%w[first second]) }
      .to raise_error(Woods::Embedding::Provider::InvalidEmbeddingResponse, /dimension/)
  end

  [[0.1], [0.1, Float::NAN], 'invalid', []].each do |bad_vector|
    it "refuses malformed cached vectors #{bad_vector.inspect} without an API call" do
      provider = openai(dimensions: 2)
      allow(cache).to receive(:read).and_return(bad_vector)
      expect(provider).not_to receive(:embed)

      expect { cached(provider).embed('query') }
        .to raise_error(Woods::Embedding::Provider::InvalidEmbeddingResponse)
    end
  end

  it 'validates a whole provider batch before caching any vector' do
    provider = openai(dimensions: 2)
    allow(provider).to receive(:embed_batch).and_return([[0.1, 0.2], [0.3]])
    expect(cache).not_to receive(:write)

    expect { cached(provider).embed_batch(%w[first second]) }
      .to raise_error(Woods::Embedding::Provider::InvalidEmbeddingResponse)
  end
end
