# frozen_string_literal: true

require_relative 'retriever'
require_relative 'storage/vector_store'
require_relative 'storage/pgvector'
require_relative 'storage/qdrant'
require_relative 'storage/metadata_store'
require_relative 'storage/graph_store'
require_relative 'embedding/provider'
require_relative 'embedding/openai'

module CodebaseIndex
  # Builder reads a {Configuration} and instantiates the appropriate adapters,
  # returning a fully wired {Retriever} ready for use.
  #
  # Named presets are provided for common deployment scenarios. All presets can
  # be further customized with a block passed to {CodebaseIndex.configure_with_preset}.
  #
  # @example Using a preset
  #   CodebaseIndex.configure_with_preset(:local)
  #   result = CodebaseIndex.retrieve("How does the User model work?")
  #
  # @example Using a preset with block customization
  #   CodebaseIndex.configure_with_preset(:production) do |config|
  #     config.embedding_options = { api_key: ENV['OPENAI_API_KEY'] }
  #     config.vector_store_options = { url: ENV['QDRANT_URL'], collection: 'myapp' }
  #   end
  #
  class Builder
    # Named presets mapping to default adapter types.
    #
    # :local      — fully local, no external services required
    # :postgresql — pgvector for vectors, OpenAI for embeddings
    # :production — Qdrant for vectors, OpenAI for embeddings
    PRESETS = {
      local: {
        vector_store: :in_memory,
        metadata_store: :sqlite,
        graph_store: :in_memory,
        embedding_provider: :ollama
      },
      postgresql: {
        vector_store: :pgvector,
        metadata_store: :sqlite,
        graph_store: :in_memory,
        embedding_provider: :openai
      },
      production: {
        vector_store: :qdrant,
        metadata_store: :sqlite,
        graph_store: :in_memory,
        embedding_provider: :openai
      }
    }.freeze

    # Build a {Configuration} populated with the named preset's adapter types.
    #
    # @param name [Symbol] Preset name — one of :local, :postgresql, or :production
    # @return [Configuration] A new Configuration with preset values applied
    # @raise [ArgumentError] if the preset name is not recognized
    def self.preset_config(name)
      preset = PRESETS.fetch(name) do
        raise ArgumentError, "Unknown preset: #{name}. Valid: #{PRESETS.keys.join(', ')}"
      end
      config = Configuration.new
      preset.each { |key, value| config.public_send(:"#{key}=", value) }
      config
    end

    # @param config [Configuration] Configuration to read adapter types from
    def initialize(config = CodebaseIndex.configuration)
      @config = config
    end

    # Build a {Retriever} wired with adapters from the configuration.
    #
    # @return [Retriever] A fully instantiated, wired retriever
    def build_retriever
      Retriever.new(
        vector_store: build_vector_store,
        metadata_store: build_metadata_store,
        graph_store: build_graph_store,
        embedding_provider: build_embedding_provider
      )
    end

    # Instantiate the vector store adapter specified by the configuration.
    #
    # @return [Storage::VectorStore::Interface] Vector store adapter instance
    # @raise [ArgumentError] if the configured type is not recognized
    def build_vector_store
      case @config.vector_store
      when :in_memory then Storage::VectorStore::InMemory.new
      when :pgvector then Storage::VectorStore::Pgvector.new(**(@config.vector_store_options || {}))
      when :qdrant then Storage::VectorStore::Qdrant.new(**(@config.vector_store_options || {}))
      else raise ArgumentError, "Unknown vector_store: #{@config.vector_store}"
      end
    end

    # Instantiate the embedding provider specified by the configuration.
    #
    # @return [Embedding::Provider::Interface] Embedding provider instance
    # @raise [ArgumentError] if the configured type is not recognized
    def build_embedding_provider
      case @config.embedding_provider
      when :openai then Embedding::Provider::OpenAI.new(**(@config.embedding_options || {}))
      when :ollama then Embedding::Provider::Ollama.new(**(@config.embedding_options || {}))
      else raise ArgumentError, "Unknown embedding_provider: #{@config.embedding_provider}"
      end
    end

    private

    # Instantiate the metadata store adapter specified by the configuration.
    #
    # @return [Storage::MetadataStore::Interface] Metadata store adapter instance
    # @raise [ArgumentError] if the configured type is not recognized
    def build_metadata_store
      case @config.metadata_store
      when :in_memory then Storage::MetadataStore::InMemory.new
      when :sqlite then Storage::MetadataStore::SQLite.new(**(@config.metadata_store_options || {}))
      else raise ArgumentError, "Unknown metadata_store: #{@config.metadata_store}"
      end
    end

    # Instantiate the graph store adapter specified by the configuration.
    #
    # @return [Storage::GraphStore::Interface] Graph store adapter instance
    # @raise [ArgumentError] if the configured type is not recognized
    def build_graph_store
      case @config.graph_store
      when :in_memory then Storage::GraphStore::Memory.new
      else raise ArgumentError, "Unknown graph_store: #{@config.graph_store}"
      end
    end
  end
end
