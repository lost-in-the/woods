# frozen_string_literal: true

module CodebaseIndex
  module Console
    module Adapters
      # Cache adapter that auto-detects the active cache store.
      #
      # Supports Redis, Solid Cache, memory, and file cache stores.
      # Detection checks Rails.cache class name first, then falls back
      # to checking for SolidCache constant.
      #
      # @example
      #   CacheAdapter.detect  # => :redis
      #   CacheAdapter.stats   # => { tool: 'cache_stats', params: {} }
      #
      module CacheAdapter
        STORE_PATTERNS = {
          'RedisCacheStore' => :redis,
          'MemoryStore' => :memory,
          'FileStore' => :file
        }.freeze

        module_function

        # Detect the active cache store backend.
        #
        # @return [Symbol] One of :redis, :solid_cache, :memory, :file, :unknown
        def detect
          if defined?(::Rails) && ::Rails.respond_to?(:cache) && ::Rails.cache
            class_name = ::Rails.cache.class.name.to_s
            STORE_PATTERNS.each do |pattern, backend|
              return backend if class_name.include?(pattern)
            end
          end

          return :solid_cache if defined?(::SolidCache)

          :unknown
        end

        # Get cache store statistics.
        #
        # @param namespace [String, nil] Cache namespace filter
        # @return [Hash] Bridge request
        def stats(namespace: nil)
          { tool: 'cache_stats', params: { namespace: namespace }.compact }
        end

        # Get cache store info (backend type, configuration).
        #
        # @return [Hash] Bridge request
        def info
          { tool: 'cache_info', params: {} }
        end
      end
    end
  end
end
