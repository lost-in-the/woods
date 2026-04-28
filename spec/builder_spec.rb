# frozen_string_literal: true

require 'spec_helper'
require 'woods'
require 'woods/builder'

RSpec.describe Woods::Builder do
  # Stub adapter constructors so we don't need real backends
  let(:fake_vector_store) { instance_double('VectorStore') }
  let(:fake_metadata_store) { instance_double('MetadataStore') }
  let(:fake_graph_store) { instance_double('GraphStore') }
  let(:fake_embedding_provider) { instance_double('EmbeddingProvider') }
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

    it 'passes the embedding provider to Retriever' do
      expect(Woods::Retriever).to receive(:new)
        .with(hash_including(embedding_provider: fake_embedding_provider))
        .and_return(fake_retriever)

      described_class.new(config).build_retriever
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
  end

  # ── options hashes are passed through ────────────────────────────────

  describe 'options pass-through' do
    let(:config) do
      Woods::Configuration.new.tap do |c|
        c.vector_store = :qdrant
        c.vector_store_options = { url: 'http://qdrant:6333', collection: 'myapp' }
        c.metadata_store = :sqlite
        c.metadata_store_options = { db_path: '/tmp/meta.db' }
        c.graph_store = :in_memory
        c.embedding_provider = :openai
        c.embedding_options = { api_key: 'sk-test' }
      end
    end

    before do
      allow(Woods::Storage::MetadataStore::SQLite).to receive(:new).and_return(fake_metadata_store)
      allow(Woods::Storage::GraphStore::Memory).to receive(:new).and_return(fake_graph_store)
      allow(Woods::Retriever).to receive(:new).and_return(fake_retriever)
    end

    it 'passes vector_store_options to the vector store constructor' do
      expect(Woods::Storage::VectorStore::Qdrant)
        .to receive(:new)
        .with(url: 'http://qdrant:6333', collection: 'myapp')
        .and_return(fake_vector_store)

      described_class.new(config).build_retriever
    end

    it 'passes metadata_store_options to the metadata store constructor' do
      allow(Woods::Storage::VectorStore::Qdrant).to receive(:new).and_return(fake_vector_store)

      expect(Woods::Storage::MetadataStore::SQLite)
        .to receive(:new)
        .with(db_path: '/tmp/meta.db')
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
end
