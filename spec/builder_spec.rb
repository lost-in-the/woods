# frozen_string_literal: true

require 'spec_helper'
require 'woods'
require 'woods/builder'

RSpec.describe Woods::Builder do
  # Stub adapter constructors so we don't need real backends
  let(:fake_vector_store) { double('VectorStore') }
  let(:fake_metadata_store) { double('MetadataStore') }
  let(:fake_graph_store) { double('GraphStore') }
  let(:fake_embedding_provider) { double('EmbeddingProvider', dimensions: 1536) }
  let(:fake_retriever) { instance_double(Woods::Retriever) }

  # ── Builder.preset_config ────────────────────────────────────────────

  describe '.preset_config' do
    describe ':local preset' do
      subject(:config) { described_class.preset_config(:local) }

      it 'returns a Configuration' do
        expect(config).to be_a(Woods::Configuration)
      end

      it 'sets vector_store to :in_memory' do
        expect(config.vector_store).to eq(:in_memory)
      end

      it 'sets metadata_store to :sqlite' do
        expect(config.metadata_store).to eq(:sqlite)
      end

      it 'sets graph_store to :in_memory' do
        expect(config.graph_store).to eq(:in_memory)
      end

      it 'sets embedding_provider to :ollama' do
        expect(config.embedding_provider).to eq(:ollama)
      end
    end

    describe ':postgresql preset' do
      subject(:config) { described_class.preset_config(:postgresql) }

      it 'returns a Configuration' do
        expect(config).to be_a(Woods::Configuration)
      end

      it 'sets vector_store to :pgvector' do
        expect(config.vector_store).to eq(:pgvector)
      end

      it 'sets metadata_store to :sqlite' do
        expect(config.metadata_store).to eq(:sqlite)
      end

      it 'sets graph_store to :in_memory' do
        expect(config.graph_store).to eq(:in_memory)
      end

      it 'sets embedding_provider to :openai' do
        expect(config.embedding_provider).to eq(:openai)
      end
    end

    describe ':production preset' do
      subject(:config) { described_class.preset_config(:production) }

      it 'returns a Configuration' do
        expect(config).to be_a(Woods::Configuration)
      end

      it 'sets vector_store to :qdrant' do
        expect(config.vector_store).to eq(:qdrant)
      end

      it 'sets metadata_store to :sqlite' do
        expect(config.metadata_store).to eq(:sqlite)
      end

      it 'sets graph_store to :in_memory' do
        expect(config.graph_store).to eq(:in_memory)
      end

      it 'sets embedding_provider to :openai' do
        expect(config.embedding_provider).to eq(:openai)
      end
    end

    describe ':shared_filesystem preset' do
      subject(:config) { described_class.preset_config(:shared_filesystem) }

      # Shape 2 in the persistence plan: rake embed writes to output_dir,
      # separate MCP server reads the dump. All stores :in_memory;
      # persistence is via the Snapshotter, not SQLite. Works on MySQL
      # and Postgres hosts that don't bundle the sqlite3 gem.
      it 'returns a Configuration' do
        expect(config).to be_a(Woods::Configuration)
      end

      it 'sets vector_store to :in_memory (persisted via Snapshotter)' do
        expect(config.vector_store).to eq(:in_memory)
      end

      it 'sets metadata_store to :in_memory (no sqlite3 gem required)' do
        expect(config.metadata_store).to eq(:in_memory)
      end

      it 'sets graph_store to :in_memory' do
        expect(config.graph_store).to eq(:in_memory)
      end

      it 'sets embedding_provider to :ollama' do
        expect(config.embedding_provider).to eq(:ollama)
      end
    end

    describe 'invalid preset' do
      it 'raises ArgumentError' do
        expect { described_class.preset_config(:invalid) }
          .to raise_error(ArgumentError, /Unknown preset: invalid/)
      end

      it 'includes valid preset names in the error message' do
        expect { described_class.preset_config(:bogus) }
          .to raise_error(ArgumentError, /local.*postgresql.*production/)
      end
    end
  end

  # ── Woods.configure_with_preset ─────────────────────────────

  describe 'Woods.configure_with_preset' do
    before { Woods.configuration = nil }

    after { Woods.configuration = nil }

    it 'sets the global configuration from a preset' do
      Woods.configure_with_preset(:local)

      expect(Woods.configuration.vector_store).to eq(:in_memory)
      expect(Woods.configuration.embedding_provider).to eq(:ollama)
    end

    it 'yields the configuration for block customization' do
      Woods.configure_with_preset(:local) do |config|
        config.output_dir = '/tmp/test_output'
      end

      expect(Woods.configuration.output_dir).to eq('/tmp/test_output')
    end

    it 'block customization does not override preset adapter types' do
      Woods.configure_with_preset(:local) do |config|
        config.output_dir = '/tmp/test_output'
      end

      expect(Woods.configuration.vector_store).to eq(:in_memory)
    end

    it 'block customization can override preset adapter types' do
      Woods.configure_with_preset(:local) do |config|
        config.embedding_provider = :openai
      end

      expect(Woods.configuration.embedding_provider).to eq(:openai)
    end

    it 'raises ArgumentError for unknown preset' do
      expect { Woods.configure_with_preset(:unknown) }
        .to raise_error(ArgumentError, /Unknown preset/)
    end
  end

  # ── Builder#build_retriever ─────────────────────────────────────────

  describe '#build_retriever' do
    let(:config) do
      Woods::Configuration.new.tap do |c|
        c.vector_store = :in_memory
        c.metadata_store = :sqlite
        c.graph_store = :in_memory
        c.embedding_provider = :ollama
      end
    end

    before do
      allow(Woods::Storage::VectorStore::InMemory).to receive(:new).and_return(fake_vector_store)
      allow(Woods::Storage::MetadataStore::SQLite).to receive(:new).and_return(fake_metadata_store)
      allow(Woods::Storage::GraphStore::Memory).to receive(:new).and_return(fake_graph_store)
      allow(Woods::Embedding::Provider::Ollama).to receive(:new).and_return(fake_embedding_provider)
      allow(Woods::Retriever).to receive(:new).and_return(fake_retriever)
    end

    it 'returns a Retriever' do
      result = described_class.new(config).build_retriever

      expect(result).to eq(fake_retriever)
    end

    it 'passes the vector store to Retriever' do
      expect(Woods::Retriever).to receive(:new)
        .with(hash_including(vector_store: fake_vector_store))
        .and_return(fake_retriever)

      described_class.new(config).build_retriever
    end

    it 'passes the metadata store to Retriever' do
      expect(Woods::Retriever).to receive(:new)
        .with(hash_including(metadata_store: fake_metadata_store))
        .and_return(fake_retriever)

      described_class.new(config).build_retriever
    end

    it 'passes the graph store to Retriever' do
      expect(Woods::Retriever).to receive(:new)
        .with(hash_including(graph_store: fake_graph_store))
        .and_return(fake_retriever)

      described_class.new(config).build_retriever
    end

    # B-076 / #188 — the raw provider used to be handed straight to the
    # Retriever, so a single 429/5xx from the provider aborted retrieval
    # with no retry and no breaker.
    it 'passes the embedding provider to Retriever wrapped in the resilience stack' do
      expect(Woods::Retriever).to receive(:new) do |kwargs|
        wrapped = kwargs[:embedding_provider]
        expect(wrapped).to be_a(Woods::Resilience::RetryableProvider)
        expect(wrapped.provider).to be(fake_embedding_provider)
        fake_retriever
      end

      described_class.new(config).build_retriever
    end
  end

  # ── Builder#build_resilient_embedding_provider (#188 / B-076) ─────────

  describe '#build_resilient_embedding_provider' do
    let(:config) do
      Woods::Configuration.new.tap do |c|
        c.vector_store = :in_memory
        c.metadata_store = :sqlite
        c.graph_store = :in_memory
        c.embedding_provider = :ollama
      end
    end

    let(:builder) { described_class.new(config) }

    before do
      allow(Woods::Embedding::Provider::Ollama).to receive(:new).and_return(fake_embedding_provider)
    end

    it 'returns the provider wrapped in RetryableProvider' do
      expect(builder.build_resilient_embedding_provider)
        .to be_a(Woods::Resilience::RetryableProvider)
    end

    it 'wraps a freshly built provider from configuration by default' do
      expect(builder.build_resilient_embedding_provider.provider).to be(fake_embedding_provider)
    end

    it 'wraps an explicitly passed provider without rebuilding' do
      other = double('OtherProvider')

      wrapped = builder.build_resilient_embedding_provider(other)

      expect(wrapped.provider).to be(other)
      expect(Woods::Embedding::Provider::Ollama).not_to have_received(:new)
    end

    it 'attaches a circuit breaker to the wrapped provider' do
      expect(builder.build_resilient_embedding_provider.circuit_breaker)
        .to be_a(Woods::Resilience::CircuitBreaker)
    end

    # CLAUDE.md: breaker state is per-instance, never shared across
    # unrelated components — two builds must not share breaker state.
    it 'gives each wrapped provider its own breaker instance' do
      first = builder.build_resilient_embedding_provider
      second = builder.build_resilient_embedding_provider

      expect(first.circuit_breaker).not_to be(second.circuit_breaker)
    end

    it 'does not share breakers across Builder instances either' do
      other_builder = described_class.new(config)

      expect(builder.build_resilient_embedding_provider.circuit_breaker)
        .not_to be(other_builder.build_resilient_embedding_provider.circuit_breaker)
    end
  end

  # ── Public API: build_vector_store and build_embedding_provider ──────

  describe 'public builder methods' do
    let(:config) do
      Woods::Configuration.new.tap do |c|
        c.vector_store = :in_memory
        c.metadata_store = :sqlite
        c.graph_store = :in_memory
        c.embedding_provider = :ollama
      end
    end

    let(:builder) { described_class.new(config) }

    it 'exposes build_vector_store as a public method' do
      expect(builder).to respond_to(:build_vector_store)
    end

    it 'exposes build_embedding_provider as a public method' do
      expect(builder).to respond_to(:build_embedding_provider)
    end
  end

  describe '#build_metadata_store with a durable preset' do
    it 'derives a file-backed SQLite database from output_dir' do
      Dir.mktmpdir('woods-builder-metadata') do |dir|
        config = described_class.preset_config(:local)
        config.output_dir = dir

        store = described_class.new(config).build_metadata_store
        store.store('User', type: 'model')

        expect(File).to exist(File.join(dir, 'metadata.sqlite3'))
        expect(store.find('User')).to include('type' => 'model')
      end
    end
  end

  # ── Builder#build_chunker — budget guard ──────────────────────────────

  describe '#build_chunker budget guard' do
    let(:config) { Woods::Configuration.new }
    let(:builder) { described_class.new(config) }

    # A provider whose context window leaves no headroom after the
    # CHUNKER_PREFIX_ALLOWANCE (512 chars). Without the guard, the
    # negative max_chars lands in SemanticChunker#slice_by_lines and
    # silently drops every chunk — see PR #70 review notes.
    let(:tiny_provider) do
      Class.new(Woods::Embedding::Provider::Ollama) do
        def initialize
          super(model: 'tiny-test-model', num_ctx: 64)
        end
      end.new
    end

    it 'raises ArgumentError when max_chars would be non-positive' do
      expect { builder.build_chunker(tiny_provider) }
        .to raise_error(ArgumentError, /no room for the chunk prefix/)
    end

    it 'still builds a chunker when the budget leaves positive headroom' do
      reasonable = Woods::Embedding::Provider::Ollama.new(model: 'all-minilm')
      expect { builder.build_chunker(reasonable) }.not_to raise_error
    end
  end

  # ── Builder#build_vector_store — :pgvector schema wiring (#187) ──────

  describe '#build_vector_store with :pgvector (#187)' do
    let(:fake_connection) { double('connection') }
    let(:pg_store) { instance_double(Woods::Storage::VectorStore::Pgvector) }
    let(:config) do
      Woods::Configuration.new.tap do |c|
        c.vector_store = :pgvector
        c.vector_store_options = { connection: fake_connection, dimensions: 3 }
      end
    end

    before do
      allow(Woods::Storage::VectorStore::Pgvector).to receive(:new)
        .with(connection: fake_connection, dimensions: 3)
        .and_return(pg_store)
    end

    it 'calls ensure_schema! after construction so the woods_vectors table exists' do
      expect(pg_store).to receive(:ensure_schema!)

      expect(described_class.new(config).build_vector_store).to eq(pg_store)
    end

    it 'wraps schema-setup failures in Woods::Error with a diagnosable message' do
      allow(pg_store).to receive(:ensure_schema!)
        .and_raise(StandardError, 'connection to server was lost')

      expect { described_class.new(config).build_vector_store }
        .to raise_error(Woods::Error, /pgvector schema setup failed.*connection to server was lost/)
    end

    it 'preserves the original error as the cause' do
      allow(pg_store).to receive(:ensure_schema!)
        .and_raise(StandardError, 'no pg_hba.conf entry')

      expect { described_class.new(config).build_vector_store }
        .to raise_error(Woods::Error) { |e| expect(e.cause.message).to eq('no pg_hba.conf entry') }
    end

    it 'rejects dimensions that disagree with the embedding provider' do
      expect { described_class.new(config).build_vector_store(dimensions: 4) }
        .to raise_error(Woods::ConfigurationError, /pgvector dimensions 3.*provider dimensions 4/i)
    end

    it 'uses the provider dimensions when vector_store_options omits them' do
      config.vector_store_options = { connection: fake_connection }
      expect(Woods::Storage::VectorStore::Pgvector).to receive(:new)
        .with(connection: fake_connection, dimensions: 4)
        .and_return(pg_store)
      expect(pg_store).to receive(:ensure_schema!)

      expect(described_class.new(config).build_vector_store(dimensions: 4)).to eq(pg_store)
    end

    it 'uses the provider dimensions when build_retriever constructs pgvector' do
      config.vector_store_options = { connection: fake_connection }
      config.embedding_provider = Woods::Embedding::Provider::Fake.new(dims: 1536)
      config.metadata_store = :in_memory
      config.graph_store = :in_memory

      expect(Woods::Storage::VectorStore::Pgvector).to receive(:new)
        .with(connection: fake_connection, dimensions: 1536)
        .and_return(pg_store)
      expect(pg_store).to receive(:ensure_schema!)
      allow(Woods::Storage::MetadataStore::InMemory).to receive(:new).and_return(fake_metadata_store)
      allow(Woods::Storage::GraphStore::Memory).to receive(:new).and_return(fake_graph_store)
      allow(Woods::Retriever).to receive(:new).and_return(fake_retriever)

      expect(described_class.new(config).build_retriever).to eq(fake_retriever)
    end
  end

  describe '#build_vector_store with :qdrant' do
    let(:qdrant_store) { instance_double(Woods::Storage::VectorStore::Qdrant) }
    let(:config) do
      Woods::Configuration.new.tap do |c|
        c.vector_store = :qdrant
        c.vector_store_options = {
          url: 'https://qdrant.example.test',
          collection: 'woods_test',
          dimensions: 384
        }
      end
    end

    it 'creates or verifies the configured collection during construction' do
      expect(Woods::Storage::VectorStore::Qdrant).to receive(:new)
        .with(url: 'https://qdrant.example.test', collection: 'woods_test', dimensions: 384)
        .and_return(qdrant_store)
      expect(qdrant_store).to receive(:ensure_collection!).with(dimensions: 384)

      expect(described_class.new(config).build_vector_store).to eq(qdrant_store)
    end
  end

  # ── Builder#build_vector_store — unknown type ────────────────────────

  describe '#build_vector_store with unknown type' do
    let(:config) do
      Woods::Configuration.new.tap do |c|
        c.vector_store = :cassandra
        c.metadata_store = :sqlite
        c.graph_store = :in_memory
        c.embedding_provider = :ollama
      end
    end

    it 'raises ArgumentError' do
      expect { described_class.new(config).build_retriever }
        .to raise_error(ArgumentError, /Unknown vector_store: cassandra/)
    end
  end

  # ── Builder#build_metadata_store — unknown type ───────────────────────

  describe '#build_metadata_store with unknown type' do
    let(:config) do
      Woods::Configuration.new.tap do |c|
        c.vector_store = :in_memory
        c.metadata_store = :postgres
        c.graph_store = :in_memory
        c.embedding_provider = :ollama
      end
    end

    before do
      allow(Woods::Storage::VectorStore::InMemory).to receive(:new).and_return(fake_vector_store)
    end

    it 'raises ArgumentError' do
      expect { described_class.new(config).build_retriever }
        .to raise_error(ArgumentError, /Unknown metadata_store: postgres/)
    end
  end

  # ── Builder#build_graph_store — unknown type ─────────────────────────

  describe '#build_graph_store with unknown type' do
    let(:config) do
      Woods::Configuration.new.tap do |c|
        c.vector_store = :in_memory
        c.metadata_store = :sqlite
        c.graph_store = :neo4j
        c.embedding_provider = :ollama
      end
    end

    before do
      allow(Woods::Storage::VectorStore::InMemory).to receive(:new).and_return(fake_vector_store)
      allow(Woods::Storage::MetadataStore::SQLite).to receive(:new).and_return(fake_metadata_store)
    end

    it 'raises ArgumentError' do
      expect { described_class.new(config).build_retriever }
        .to raise_error(ArgumentError, /Unknown graph_store: neo4j/)
    end
  end

  # ── Builder#build_embedding_provider — unknown type ──────────────────

  describe '#build_embedding_provider with unknown type' do
    let(:config) do
      Woods::Configuration.new.tap do |c|
        c.vector_store = :in_memory
        c.metadata_store = :sqlite
        c.graph_store = :in_memory
        c.embedding_provider = :cohere
      end
    end

    before do
      allow(Woods::Storage::VectorStore::InMemory).to receive(:new).and_return(fake_vector_store)
      allow(Woods::Storage::MetadataStore::SQLite).to receive(:new).and_return(fake_metadata_store)
      allow(Woods::Storage::GraphStore::Memory).to receive(:new).and_return(fake_graph_store)
    end

    it 'raises ArgumentError' do
      expect { described_class.new(config).build_retriever }
        .to raise_error(ArgumentError, /Unknown embedding_provider: cohere/)
    end

    # #178 — the error must teach the fix: name every valid option,
    # including the offline :fake provider and the object-injection escape
    # hatch.
    it 'names the valid options including :fake in the error message' do
      expect { described_class.new(config).build_retriever }
        .to raise_error(ArgumentError, /:openai, :ollama, :fake.*#embed and #embed_batch/)
    end
  end

  # ── Builder#build_embedding_provider — :fake (#178) ──────────────────

  describe '#build_embedding_provider with :fake' do
    let(:config) do
      Woods::Configuration.new.tap { |c| c.embedding_provider = :fake }
    end

    let(:builder) { described_class.new(config) }

    it 'returns the promoted deterministic provider' do
      expect(builder.build_embedding_provider).to be_a(Woods::Embedding::Provider::Fake)
    end

    it 'defaults to the provider default dimensionality' do
      expect(builder.build_embedding_provider.dimensions)
        .to eq(Woods::Embedding::Provider::Fake::DEFAULT_DIMS)
    end

    it 'honours embedding_options[:dims]' do
      config.embedding_options = { dims: 64 }

      expect(builder.build_embedding_provider.dimensions).to eq(64)
    end

    # The :dimension key is normally snapshot-only bookkeeping stripped by
    # provider_kwargs — but it is also the key the MCP boot path restores
    # from woods.json, so the fake honours it as a dims fallback.
    it 'honours the snapshot-level embedding_options[:dimension] key' do
      config.embedding_options = { dimension: 32 }

      expect(builder.build_embedding_provider.dimensions).to eq(32)
    end

    it 'prefers :dims over :dimension when both are set' do
      config.embedding_options = { dims: 64, dimension: 32 }

      expect(builder.build_embedding_provider.dimensions).to eq(64)
    end

    it 'embeds without any network endpoint' do
      vector = builder.build_embedding_provider.embed('class User < ApplicationRecord; end')

      expect(vector.length).to eq(Woods::Embedding::Provider::Fake::DEFAULT_DIMS)
    end

    # #178 — the fake never 429s, so the wrap is a no-op, but it must still
    # apply so every pipeline entry point treats providers uniformly.
    it 'is wrapped in the resilience stack like the network providers' do
      wrapped = builder.build_resilient_embedding_provider

      expect(wrapped).to be_a(Woods::Resilience::RetryableProvider)
      expect(wrapped.provider).to be_a(Woods::Embedding::Provider::Fake)
      expect(wrapped.circuit_breaker).to be_a(Woods::Resilience::CircuitBreaker)
    end

    it 'embeds through the resilience wrapper transparently' do
      wrapped = builder.build_resilient_embedding_provider

      expect(wrapped.embed('some woods text').length)
        .to eq(Woods::Embedding::Provider::Fake::DEFAULT_DIMS)
    end
  end

  describe '#build_embedding_provider configuration' do
    let(:config) { Woods::Configuration.new }
    let(:builder) { described_class.new(config) }

    it 'passes an explicitly configured embedding_model to Ollama' do
      config.embedding_provider = :ollama
      config.embedding_model = 'mxbai-embed-large'

      expect(builder.build_embedding_provider.model_name).to eq('mxbai-embed-large')
    end

    it 'keeps the Ollama model default when embedding_model was not explicitly configured' do
      config.embedding_provider = :ollama

      expect(builder.build_embedding_provider.model_name)
        .to eq(Woods::Embedding::Provider::Ollama::DEFAULT_MODEL)
    end

    it 'passes an explicitly configured embedding_model to OpenAI' do
      config.embedding_provider = :openai
      config.embedding_model = 'text-embedding-3-large'
      config.embedding_options = { api_key: 'sk-test' }

      expect(builder.build_embedding_provider.model_name).to eq('text-embedding-3-large')
    end

    it 'lets provider-specific model configuration override embedding_model' do
      config.embedding_provider = :ollama
      config.embedding_model = 'nomic-embed-text'
      config.embedding_options = { model: 'bge-m3' }

      expect(builder.build_embedding_provider.model_name).to eq('bge-m3')
    end

    it 'passes dimensions through to the selected provider' do
      config.embedding_provider = :openai
      config.embedding_options = { api_key: 'sk-test', dimensions: 256 }

      expect(builder.build_embedding_provider.dimensions).to eq(256)
    end

    it 'rejects disconnected provider options with an actionable error' do
      config.embedding_provider = :ollama
      config.embedding_options = { api_key: 'not-an-ollama-option' }

      expect { builder.build_embedding_provider }
        .to raise_error(Woods::ConfigurationError, /Unknown Ollama embedding option: api_key/)
    end
  end

  # ── Builder#build_embedding_provider — injected object (#178) ─────────

  describe '#build_embedding_provider with an injected provider object' do
    let(:injected) do
      Class.new do
        def embed(_text)
          [1.0, 0.0]
        end

        def embed_batch(texts)
          texts.map { [1.0, 0.0] }
        end

        def dimensions
          2
        end

        def model_name
          'host-custom'
        end
      end.new
    end

    let(:config) do
      Woods::Configuration.new.tap do |c|
        c.vector_store = :in_memory
        c.metadata_store = :in_memory
        c.graph_store = :in_memory
        c.embedding_provider = injected
      end
    end

    let(:builder) { described_class.new(config) }

    it 'uses the object as-is' do
      expect(builder.build_embedding_provider).to be(injected)
    end

    it 'wraps the injected object in the resilience stack' do
      wrapped = builder.build_resilient_embedding_provider

      expect(wrapped).to be_a(Woods::Resilience::RetryableProvider)
      expect(wrapped.provider).to be(injected)
    end

    it 'flows through build_retriever wrapped around the same object' do
      expect(Woods::Retriever).to receive(:new) do |kwargs|
        expect(kwargs[:embedding_provider]).to be_a(Woods::Resilience::RetryableProvider)
        expect(kwargs[:embedding_provider].provider).to be(injected)
        fake_retriever
      end

      expect(builder.build_retriever).to be(fake_retriever)
    end

    it 'rejects objects that do not implement the provider interface' do
      config.embedding_provider = Object.new

      expect { builder.build_embedding_provider }
        .to raise_error(ArgumentError, /Unknown embedding_provider/)
    end
  end

  # ── options hashes are passed through ────────────────────────────────

  describe 'options pass-through' do
    let(:config) do
      Woods::Configuration.new.tap do |c|
        c.vector_store = :qdrant
        c.vector_store_options = { url: 'http://qdrant:6333', collection: 'myapp' }
        c.metadata_store = :sqlite
        c.metadata_store_options = { database: '/tmp/meta.db' }
        c.graph_store = :in_memory
        c.embedding_provider = :openai
        c.embedding_options = { api_key: 'sk-test' }
      end
    end

    before do
      allow(Woods::Storage::MetadataStore::SQLite).to receive(:new).and_return(fake_metadata_store)
      allow(Woods::Storage::GraphStore::Memory).to receive(:new).and_return(fake_graph_store)
      allow(Woods::Retriever).to receive(:new).and_return(fake_retriever)
      allow(fake_vector_store).to receive(:ensure_collection!)
    end

    it 'passes vector_store_options to the vector store constructor' do
      expect(Woods::Storage::VectorStore::Qdrant)
        .to receive(:new)
        .with(url: 'http://qdrant:6333', collection: 'myapp', dimensions: 1536)
        .and_return(fake_vector_store)
      expect(fake_vector_store).to receive(:ensure_collection!).with(dimensions: 1536)

      described_class.new(config).build_retriever
    end

    it 'passes metadata_store_options to the metadata store constructor' do
      allow(Woods::Storage::VectorStore::Qdrant).to receive(:new).and_return(fake_vector_store)

      expect(Woods::Storage::MetadataStore::SQLite)
        .to receive(:new)
        .with(database: '/tmp/meta.db')
        .and_return(fake_metadata_store)

      described_class.new(config).build_retriever
    end

    it 'passes embedding_options to the embedding provider constructor' do
      allow(Woods::Storage::VectorStore::Qdrant).to receive(:new).and_return(fake_vector_store)

      expect(Woods::Embedding::Provider::OpenAI)
        .to receive(:new)
        .with(api_key: 'sk-test')
        .and_return(fake_embedding_provider)

      described_class.new(config).build_retriever
    end
  end

  describe '#build_text_preparer' do
    let(:config) { Woods::Configuration.new }
    subject(:builder) { described_class.new(config) }

    it 'uses 1.5 chars/token for Ollama providers (BERT/WordPiece on dense Rails source)' do
      provider = Woods::Embedding::Provider::Ollama.new
      preparer = builder.build_text_preparer(provider)
      expect(preparer.chars_per_token).to eq(1.5)
    end

    it 'tracks the Ollama provider num_ctx as max_tokens' do
      provider = Woods::Embedding::Provider::Ollama.new(num_ctx: 4096)
      preparer = builder.build_text_preparer(provider)
      expect(preparer.max_tokens).to eq(4096)
    end

    it 'uses 4.0 chars/token and the 8191 cap for OpenAI providers' do
      provider = Woods::Embedding::Provider::OpenAI.new(api_key: 'sk-test')
      preparer = builder.build_text_preparer(provider)
      expect(preparer.chars_per_token).to eq(4.0)
      expect(preparer.max_tokens).to eq(8191)
    end

    it 'falls back to the preparer default when the provider has no budget' do
      provider = instance_double(Woods::Embedding::Provider::Ollama,
                                 max_input_tokens: nil, model_name: 'custom')
      preparer = builder.build_text_preparer(provider)
      expect(preparer.max_tokens).to eq(Woods::Embedding::TextPreparer::DEFAULT_MAX_TOKENS)
    end

    # #188 — calibration must see through the resilience wrapper, or a
    # wrapped Ollama silently gets OpenAI's 4.0 chars/token ratio.
    it 'calibrates a resilience-wrapped Ollama exactly like the raw provider' do
      wrapped = builder.build_resilient_embedding_provider(
        Woods::Embedding::Provider::Ollama.new(num_ctx: 4096)
      )
      preparer = builder.build_text_preparer(wrapped)
      expect(preparer.chars_per_token).to eq(1.5)
      expect(preparer.max_tokens).to eq(4096)
    end
  end

  describe '#build_chunker' do
    let(:config) { Woods::Configuration.new }
    subject(:builder) { described_class.new(config) }

    it 'sizes max_chars from provider budget and tokenizer ratio' do
      provider = Woods::Embedding::Provider::Ollama.new(num_ctx: 8192)
      chunker = builder.build_chunker(provider)

      # Stub a unit that exceeds the budget and confirm splitting happens.
      unit = Woods::ExtractedUnit.new(
        type: :service, identifier: 'Big', file_path: 's.rb'
      )
      body = (['    something_long_enough(a, b, c)'] * 2500).join("\n")
      unit.source_code = "class Big\n  def call\n#{body}\n  end\nend"
      unit.metadata = {}

      chunks = chunker.chunk(unit)
      # 8192 * 1.5 - 512 = 11776 chars
      expect(chunks.map(&:content)).to all(satisfy { |c| c.length <= 11_776 })
    end

    it 'disables the safety net when the provider advertises no budget' do
      provider = Woods::Embedding::Provider::Ollama.new(num_ctx: nil)
      chunker = builder.build_chunker(provider)
      # A tiny unit should still produce exactly one :whole chunk.
      unit = Woods::ExtractedUnit.new(type: :service, identifier: 'Tiny', file_path: 't.rb')
      unit.source_code = "class Tiny\nend"
      unit.metadata = {}
      expect(chunker.chunk(unit).size).to eq(1)
    end

    it 'wires a TokenCounter for Ollama providers' do
      provider = Woods::Embedding::Provider::Ollama.new(num_ctx: 8192)
      chunker = builder.build_chunker(provider)
      counter = chunker.instance_variable_get(:@token_counter)
      max_tokens = chunker.instance_variable_get(:@max_tokens)
      expect(counter).to be_a(Woods::Embedding::TokenCounter)
      expect(max_tokens).to eq(8192 - 256)
    end

    it 'skips the TokenCounter for OpenAI (tiktoken ratios are stable)' do
      provider = Woods::Embedding::Provider::OpenAI.new(api_key: 'sk-test')
      chunker = builder.build_chunker(provider)
      expect(chunker.instance_variable_get(:@token_counter)).to be_nil
    end

    # #188 — same see-through requirement as build_text_preparer: a
    # resilience-wrapped Ollama must still get its TokenCounter.
    it 'wires a TokenCounter for a resilience-wrapped Ollama provider' do
      wrapped = builder.build_resilient_embedding_provider(
        Woods::Embedding::Provider::Ollama.new(num_ctx: 8192)
      )
      chunker = builder.build_chunker(wrapped)
      expect(chunker.instance_variable_get(:@token_counter)).to be_a(Woods::Embedding::TokenCounter)
    end
  end
end
