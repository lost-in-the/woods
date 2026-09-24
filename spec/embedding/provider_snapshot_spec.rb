# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'woods'
require 'woods/builder'
require 'woods/resolved_config'
require 'woods/index_artifact'
require 'woods/mcp/config_resolver'
require 'woods/mcp/bootstrapper'
require 'woods/cache/cache_middleware'

RSpec.describe 'Embedding provider snapshot restoration' do
  around do |example|
    Dir.mktmpdir('woods provider snapshot ') do |directory|
      @artifact = Woods::IndexArtifact.new(directory)
      example.run
    end
  end

  before do
    expect_any_instance_of(Net::HTTP).not_to receive(:start)
  end

  def configuration(provider, options = {})
    Woods::Configuration.new.tap do |config|
      config.embedding_provider = provider
      config.embedding_options = options
    end
  end

  def wrap(provider, kind)
    case kind
    when :retry
      Woods::Resilience::RetryableProvider.new(provider: provider)
    when :cache_retry
      Woods::Cache::CachedEmbeddingProvider.new(provider: wrap(provider, :retry),
                                                cache_store: Woods::Cache::InMemory.new)
    when :retry_cache
      Woods::Resilience::RetryableProvider.new(provider: Woods::Cache::CachedEmbeddingProvider.new(
        provider: provider, cache_store: Woods::Cache::InMemory.new
      ))
    else provider
    end
  end

  def capture(config, **options)
    snapshot = Woods::ResolvedConfig.from_configuration(config, **options).to_snapshot_json
    Woods::ResolvedConfig.from_hash(JSON.parse(JSON.generate(snapshot)))
  end

  def restore(stored, config: configuration(nil))
    restored, = Woods::MCP::ConfigResolver.resolve(config, artifact: @artifact, stored_config: stored,
                                                           env: { 'OPENAI_API_KEY' => 'restored-api-key-sentinel' })
    Woods::Builder.new(restored).build_embedding_provider
  end

  %i[raw retry cache_retry retry_cache].each do |wrapper|
    it "round-trips the effective injected Ollama settings through #{wrapper} without declarations" do
      original = Woods::Embedding::Provider::Ollama.new(host: 'http://embedding.example.test:11499',
                                                        model: 'custom-model', num_ctx: 8192,
                                                        read_timeout: 47, dimensions: 3)
      wrapped = wrap(original, wrapper)
      stored = capture(configuration(wrapped), provider: wrapped)
      expect(stored.embedding_provider).to include(host: 'http://embedding.example.test:11499', num_ctx: 8192,
                                                   read_timeout: 47, model: 'custom-model', dimension: 3,
                                                   requested_dimensions: 3)
      restored = restore(stored)
      expect(restored.cache_identity).to eq(original.cache_identity)
      expect(restored.max_input_tokens).to eq(8192)
      expect(restored.send(:build_body, 'query')).to eq(original.send(:build_body, 'query'))
      expect(restored.instance_variable_get(:@read_timeout)).to eq(47)
    end
  end

  it 'captures an injected provider without a separate live-provider argument or a width probe' do
    original = Woods::Embedding::Provider::Ollama.new(host: 'http://embedding.example.test', num_ctx: 4096,
                                                      expected_dimensions: 3)
    stored = capture(configuration(wrap(original, :cache_retry)))
    expect(stored.embedding_provider).to include(host: 'http://embedding.example.test', num_ctx: 4096,
                                                 dimension: 3, requested_dimensions: nil)
    restored = restore(stored)
    expect(restored.send(:build_body, 'query')).not_to have_key(:dimensions)
    expect(restored.cache_identity).to eq(original.cache_identity)
  end

  it 'uses injected effective settings instead of unrelated stale embedding_options' do
    original = Woods::Embedding::Provider::Ollama.new(host: 'http://effective.example.test', model: 'effective-model',
                                                      num_ctx: 8192, dimensions: 3)
    config = configuration(original, host: 'http://unused.example.test', model: 'unused-model', num_ctx: 512,
                                     read_timeout: 999, dimensions: 5)
    expect(restore(capture(config, provider: original)).cache_identity).to eq(original.cache_identity)
  end

  %i[openai ollama fake].product(%i[raw cache_retry]).each do |kind, wrapper|
    it "retains declarative #{kind} configuration through a #{wrapper} runtime provider" do
      options = case kind
                when :openai then { api_key: 'original-api-key-sentinel', model: 'text-embedding-3-large',
                                    dimensions: 3 }
                when :ollama then { host: 'http://configured.example.test', model: 'other-model',
                                    num_ctx: 4096, read_timeout: 35, expected_dimensions: 3 }
                else { dims: 3, model: 'fake-custom-model' }
                end
      config = configuration(kind, options)
      provider = Woods::Builder.new(config).build_embedding_provider
      stored = capture(config, provider: wrap(provider, wrapper))
      restored = restore(stored)
      expect(restored.cache_identity).to eq(provider.cache_identity)
      expect(restored.model_name).to eq(provider.model_name)
      expect(JSON.generate(stored.to_snapshot_json)).not_to include('api-key-sentinel', 'api_key')
    end
  end

  %i[raw cache_retry].each do |wrapper|
    it "restores injected OpenAI and Fake settings through #{wrapper} without serializing API keys" do
      providers = [Woods::Embedding::Provider::OpenAI.new(api_key: 'original-api-key-sentinel',
                                                          model: 'text-embedding-ada-002'),
                   Woods::Embedding::Provider::Fake.new(dims: 7, model: 'injected-fake')]
      providers.each do |provider|
        wrapped = wrap(provider, wrapper)
        stored = capture(configuration(wrapped))
        expect(restore(stored).cache_identity).to eq(provider.cache_identity)
        expect(JSON.generate(stored.to_snapshot_json)).not_to include('api-key-sentinel', 'api_key')
      end
    end
  end

  {
    userinfo: 'https://user:password-sentinel@embedding.example.test',
    path: 'https://embedding.example.test/private-path-sentinel',
    query: 'https://embedding.example.test?token=query-sentinel',
    fragment: 'https://embedding.example.test#fragment-sentinel'
  }.each do |part, host|
    it "requires explicit configuration for an endpoint with #{part}" do
      provider = Woods::Embedding::Provider::Ollama.new(host: host, dimensions: 3)
      config = configuration(provider)
      stored = capture(config, provider: wrap(provider, :cache_retry))
      expect(stored.embedding_provider).to include(requires_host_provider: true)
      serialized = JSON.generate(stored.to_snapshot_json)
      expect(serialized).not_to include(host, 'sentinel')
      expect(stored.provider_signature).not_to include(host, 'sentinel')
      expect { restore(stored) }.to raise_error(Woods::MCP::ConfigMismatch, /explicit.*provider/i) do |error|
        expect([error.message, error.details].to_s).not_to include(host, 'sentinel')
      end
      expect(restore(stored, config: config)).to equal(provider)
    end
  end

  it 'keeps unsafe legacy endpoint fields out of reserialized snapshots and diagnostics' do
    raw = capture(configuration(:ollama, dimensions: 3)).to_snapshot_json
    raw.fetch('embedding_provider')['host'] = 'https://user:legacy-secret-sentinel@example.test/secret-path-sentinel'
    stored = Woods::ResolvedConfig.from_hash(raw)
    expect(stored.embedding_provider).to include(requires_host_provider: true)
    expect(JSON.generate(stored.to_snapshot_json)).not_to include('sentinel')
    expect { restore(stored) }.to raise_error(Woods::MCP::ConfigMismatch, /explicit.*provider/i)
  end

  it 'preserves explicit declarative host overrides for non-restorable snapshots' do
    host = 'https://embedding.example.test/private-path-sentinel'
    config = configuration(:ollama, host: host, model: 'custom-model', dimensions: 3)
    provider = Woods::Builder.new(config).build_embedding_provider
    stored = capture(config, provider: provider)
    expect(stored).to be_requires_host_provider
    expect(restore(stored, config: config).cache_identity).to eq(provider.cache_identity)
  end

  it 'refuses implicit restoration before mutating a blank reader configuration' do
    config = configuration(nil, model: 'preserve-reader-options')
    config.output_dir = '/preserve/output'
    config.vector_store = :sqlite
    stored = capture(configuration(Woods::Embedding::Provider::Ollama.new(
                                     host: 'https://embedding.example.test?token=query-sentinel', dimensions: 3
                                   )))
    expect { restore(stored, config: config) }.to raise_error(Woods::MCP::ConfigMismatch)
    expect(config.embedding_provider).to be_nil
    expect(config.output_dir).to eq('/preserve/output')
    expect(config.vector_store).to eq(:sqlite)
    expect(config.embedding_options).to eq(model: 'preserve-reader-options')
  end

  it 'keeps lexical boot independent of provider restoration' do
    FileUtils.cp_r(File.join(__dir__, '../fixtures/woods/.'), @artifact.output_dir)
    stored = capture(configuration(Woods::Embedding::Provider::Ollama.new(
                                     host: 'https://embedding.example.test?token=query-sentinel', dimensions: 3
                                   )))
    File.write(@artifact.config_path, JSON.generate(stored.to_snapshot_json))
    config = configuration(nil)
    config.retrieval_mode = :lexical
    allow(Woods).to receive(:configuration).and_return(config)
    expect(Woods::MCP::ConfigResolver).not_to receive(:resolve)

    retriever, state = Woods::MCP::Bootstrapper.build_retriever(index_dir: @artifact.output_dir.to_s)
    expect(retriever).to be_a(Woods::MCP::PublishedLexicalRetriever)
    expect(state.status).to eq(:hydrated)
    expect(retriever.retrieve('Post').sources).not_to be_empty
  end

  it 'does not call an anonymous provider representation during capture' do
    provider = Class.new(Woods::Embedding::Provider::Fake) do
      def to_s
        raise 'provider representation must not be read'
      end
    end.new(dims: 3)
    stored = capture(configuration(provider), provider: provider)
    expect(stored).to be_requires_host_provider
    expect { restore(stored) }.to raise_error(Woods::MCP::ConfigMismatch, /explicit.*provider/i)
  end

  it 'does not infer a builtin from a custom class name or serialize its representation' do
    custom = Class.new(Woods::Embedding::Provider::Fake) do
      def to_s
        raise 'provider representation must not be read'
      end
    end
    stub_const('SnapshotOllamaClient', custom)
    provider = custom.new(dims: 3, model: 'custom')
    config = configuration(wrap(provider, :cache_retry))
    stored = capture(config, provider: config.embedding_provider)
    expect(stored.embedding_provider).to include(class: 'SnapshotOllamaClient', requires_host_provider: true)
    expect { restore(stored) }.to raise_error(Woods::MCP::ConfigMismatch, /explicit.*provider/i)
    expect(restore(stored, config: config)).to equal(config.embedding_provider)
  end
end
