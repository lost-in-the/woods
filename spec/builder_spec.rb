# frozen_string_literal: true

require 'spec_helper'
require 'codebase_index'
require 'codebase_index/builder'

RSpec.describe CodebaseIndex::Builder do
  # Stub adapter constructors so we don't need real backends
  let(:fake_vector_store) { instance_double('VectorStore') }
  let(:fake_metadata_store) { instance_double('MetadataStore') }
  let(:fake_graph_store) { instance_double('GraphStore') }
  let(:fake_embedding_provider) { instance_double('EmbeddingProvider') }
  let(:fake_retriever) { instance_double(CodebaseIndex::Retriever) }

  # ── Builder.preset_config ────────────────────────────────────────────

  describe '.preset_config' do
    describe ':local preset' do
      subject(:config) { described_class.preset_config(:local) }

      it 'returns a Configuration' do
        expect(config).to be_a(CodebaseIndex::Configuration)
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
        expect(config).to be_a(CodebaseIndex::Configuration)
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
        expect(config).to be_a(CodebaseIndex::Configuration)
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

  # ── CodebaseIndex.configure_with_preset ─────────────────────────────

  describe 'CodebaseIndex.configure_with_preset' do
    before { CodebaseIndex.configuration = nil }

    after { CodebaseIndex.configuration = nil }

    it 'sets the global configuration from a preset' do
      CodebaseIndex.configure_with_preset(:local)

      expect(CodebaseIndex.configuration.vector_store).to eq(:in_memory)
      expect(CodebaseIndex.configuration.embedding_provider).to eq(:ollama)
    end

    it 'yields the configuration for block customization' do
      CodebaseIndex.configure_with_preset(:local) do |config|
        config.output_dir = '/tmp/test_output'
      end

      expect(CodebaseIndex.configuration.output_dir).to eq('/tmp/test_output')
    end

    it 'block customization does not override preset adapter types' do
      CodebaseIndex.configure_with_preset(:local) do |config|
        config.output_dir = '/tmp/test_output'
      end

      expect(CodebaseIndex.configuration.vector_store).to eq(:in_memory)
    end

    it 'block customization can override preset adapter types' do
      CodebaseIndex.configure_with_preset(:local) do |config|
        config.embedding_provider = :openai
      end

      expect(CodebaseIndex.configuration.embedding_provider).to eq(:openai)
    end

    it 'raises ArgumentError for unknown preset' do
      expect { CodebaseIndex.configure_with_preset(:unknown) }
        .to raise_error(ArgumentError, /Unknown preset/)
    end
  end

  # ── Builder#build_retriever ─────────────────────────────────────────

  describe '#build_retriever' do
    let(:config) do
      CodebaseIndex::Configuration.new.tap do |c|
        c.vector_store = :in_memory
        c.metadata_store = :sqlite
        c.graph_store = :in_memory
        c.embedding_provider = :ollama
      end
    end

    before do
      allow(CodebaseIndex::Storage::VectorStore::InMemory).to receive(:new).and_return(fake_vector_store)
      allow(CodebaseIndex::Storage::MetadataStore::SQLite).to receive(:new).and_return(fake_metadata_store)
      allow(CodebaseIndex::Storage::GraphStore::Memory).to receive(:new).and_return(fake_graph_store)
      allow(CodebaseIndex::Embedding::Provider::Ollama).to receive(:new).and_return(fake_embedding_provider)
      allow(CodebaseIndex::Retriever).to receive(:new).and_return(fake_retriever)
    end

    it 'returns a Retriever' do
      result = described_class.new(config).build_retriever

      expect(result).to eq(fake_retriever)
    end

    it 'passes the vector store to Retriever' do
      expect(CodebaseIndex::Retriever).to receive(:new)
        .with(hash_including(vector_store: fake_vector_store))
        .and_return(fake_retriever)

      described_class.new(config).build_retriever
    end

    it 'passes the metadata store to Retriever' do
      expect(CodebaseIndex::Retriever).to receive(:new)
        .with(hash_including(metadata_store: fake_metadata_store))
        .and_return(fake_retriever)

      described_class.new(config).build_retriever
    end

    it 'passes the graph store to Retriever' do
      expect(CodebaseIndex::Retriever).to receive(:new)
        .with(hash_including(graph_store: fake_graph_store))
        .and_return(fake_retriever)

      described_class.new(config).build_retriever
    end

    it 'passes the embedding provider to Retriever' do
      expect(CodebaseIndex::Retriever).to receive(:new)
        .with(hash_including(embedding_provider: fake_embedding_provider))
        .and_return(fake_retriever)

      described_class.new(config).build_retriever
    end
  end

  # ── Builder#build_vector_store — unknown type ────────────────────────

  describe '#build_vector_store with unknown type' do
    let(:config) do
      CodebaseIndex::Configuration.new.tap do |c|
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
      CodebaseIndex::Configuration.new.tap do |c|
        c.vector_store = :in_memory
        c.metadata_store = :postgres
        c.graph_store = :in_memory
        c.embedding_provider = :ollama
      end
    end

    before do
      allow(CodebaseIndex::Storage::VectorStore::InMemory).to receive(:new).and_return(fake_vector_store)
    end

    it 'raises ArgumentError' do
      expect { described_class.new(config).build_retriever }
        .to raise_error(ArgumentError, /Unknown metadata_store: postgres/)
    end
  end

  # ── Builder#build_graph_store — unknown type ─────────────────────────

  describe '#build_graph_store with unknown type' do
    let(:config) do
      CodebaseIndex::Configuration.new.tap do |c|
        c.vector_store = :in_memory
        c.metadata_store = :sqlite
        c.graph_store = :neo4j
        c.embedding_provider = :ollama
      end
    end

    before do
      allow(CodebaseIndex::Storage::VectorStore::InMemory).to receive(:new).and_return(fake_vector_store)
      allow(CodebaseIndex::Storage::MetadataStore::SQLite).to receive(:new).and_return(fake_metadata_store)
    end

    it 'raises ArgumentError' do
      expect { described_class.new(config).build_retriever }
        .to raise_error(ArgumentError, /Unknown graph_store: neo4j/)
    end
  end

  # ── Builder#build_embedding_provider — unknown type ──────────────────

  describe '#build_embedding_provider with unknown type' do
    let(:config) do
      CodebaseIndex::Configuration.new.tap do |c|
        c.vector_store = :in_memory
        c.metadata_store = :sqlite
        c.graph_store = :in_memory
        c.embedding_provider = :cohere
      end
    end

    before do
      allow(CodebaseIndex::Storage::VectorStore::InMemory).to receive(:new).and_return(fake_vector_store)
      allow(CodebaseIndex::Storage::MetadataStore::SQLite).to receive(:new).and_return(fake_metadata_store)
      allow(CodebaseIndex::Storage::GraphStore::Memory).to receive(:new).and_return(fake_graph_store)
    end

    it 'raises ArgumentError' do
      expect { described_class.new(config).build_retriever }
        .to raise_error(ArgumentError, /Unknown embedding_provider: cohere/)
    end
  end

  # ── options hashes are passed through ────────────────────────────────

  describe 'options pass-through' do
    let(:config) do
      CodebaseIndex::Configuration.new.tap do |c|
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
      allow(CodebaseIndex::Storage::MetadataStore::SQLite).to receive(:new).and_return(fake_metadata_store)
      allow(CodebaseIndex::Storage::GraphStore::Memory).to receive(:new).and_return(fake_graph_store)
      allow(CodebaseIndex::Retriever).to receive(:new).and_return(fake_retriever)
    end

    it 'passes vector_store_options to the vector store constructor' do
      expect(CodebaseIndex::Storage::VectorStore::Qdrant)
        .to receive(:new)
        .with(url: 'http://qdrant:6333', collection: 'myapp')
        .and_return(fake_vector_store)

      described_class.new(config).build_retriever
    end

    it 'passes metadata_store_options to the metadata store constructor' do
      allow(CodebaseIndex::Storage::VectorStore::Qdrant).to receive(:new).and_return(fake_vector_store)

      expect(CodebaseIndex::Storage::MetadataStore::SQLite)
        .to receive(:new)
        .with(db_path: '/tmp/meta.db')
        .and_return(fake_metadata_store)

      described_class.new(config).build_retriever
    end

    it 'passes embedding_options to the embedding provider constructor' do
      allow(CodebaseIndex::Storage::VectorStore::Qdrant).to receive(:new).and_return(fake_vector_store)

      expect(CodebaseIndex::Embedding::Provider::OpenAI)
        .to receive(:new)
        .with(api_key: 'sk-test')
        .and_return(fake_embedding_provider)

      described_class.new(config).build_retriever
    end
  end
end
