# frozen_string_literal: true

module CodebaseIndex
  module Observability
    # Probes configured components and reports overall system health.
    #
    # Checks vector store, metadata store, and embedding provider by calling
    # lightweight operations on each. Components that are nil are reported
    # as :not_configured and do not affect the overall healthy? status.
    #
    # @example
    #   check = HealthCheck.new(
    #     vector_store: vector_store,
    #     metadata_store: metadata_store,
    #     embedding_provider: provider
    #   )
    #   status = check.run
    #   status.healthy?    # => true
    #   status.components  # => { vector_store: :ok, metadata_store: :ok, embedding_provider: :ok }
    #
    class HealthCheck
      # Value object representing the result of a health check.
      HealthStatus = Struct.new(:healthy?, :components, keyword_init: true)

      # @param vector_store [Object, nil] Vector store adapter (must respond to #count)
      # @param metadata_store [Object, nil] Metadata store adapter (must respond to #count)
      # @param embedding_provider [Object, nil] Embedding provider (must respond to #embed)
      def initialize(vector_store: nil, metadata_store: nil, embedding_provider: nil)
        @vector_store = vector_store
        @metadata_store = metadata_store
        @embedding_provider = embedding_provider
      end

      # Run health probes on all configured components.
      #
      # @return [HealthStatus] Result with healthy? flag and per-component status
      def run
        components = {
          vector_store: probe_store(@vector_store),
          metadata_store: probe_store(@metadata_store),
          embedding_provider: probe_provider(@embedding_provider)
        }

        all_healthy = components.values.all? { |status| %i[ok not_configured].include?(status) }

        HealthStatus.new(healthy?: all_healthy, components: components)
      end

      private

      # Probe a store component by calling #count.
      #
      # @param store [Object, nil] Store adapter
      # @return [Symbol] :ok, :error, or :not_configured
      def probe_store(store)
        return :not_configured if store.nil?

        store.count
        :ok
      rescue StandardError
        :error
      end

      # Probe an embedding provider by calling #embed with a test string.
      #
      # @param provider [Object, nil] Embedding provider
      # @return [Symbol] :ok, :error, or :not_configured
      def probe_provider(provider)
        return :not_configured if provider.nil?

        provider.embed('test')
        :ok
      rescue StandardError
        :error
      end
    end
  end
end
