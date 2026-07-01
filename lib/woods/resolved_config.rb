# frozen_string_literal: true

require 'json'
require 'time'
require_relative 'mcp/errors'

module Woods
  # Immutable Whole Value representing the resolved embedding configuration
  # captured at embed time and read back by the MCP server at boot.
  #
  # This is NOT a declared-config bag of fields — it records what was
  # *actually used* during embedding (provider class, model, host, dimension,
  # store types). The MCP server compares a stored {ResolvedConfig} against
  # the current host config to detect incompatible re-deployments.
  #
  # Build via {.from_hash} (parses +woods.json+) or {.from_configuration}
  # (captures the current {Woods::Configuration} at embed time).
  #
  # @example Parsing woods.json
  #   config = Woods::ResolvedConfig.from_hash(JSON.parse(File.read("woods.json")))
  #   config.dimension          # => 768
  #   config.provider_signature # => "Ollama/nomic-embed-text@http://host.docker.internal:11434"
  #
  # @example Asserting compatibility before hydrating stores
  #   stored = Woods::ResolvedConfig.from_hash(snapshot)
  #   live   = Woods::ResolvedConfig.from_configuration(Woods.configuration)
  #   live.assert_compatible!(stored)
  class ResolvedConfig # rubocop:disable Metrics/ClassLength
    # The only schema version this gem release can read or write.
    SCHEMA_VERSION_SUPPORTED = 1

    # @return [Integer]
    attr_reader :schema_version

    # @return [String] Gem version at embed time (e.g. "1.2.0")
    attr_reader :gem_version

    # @return [Time]
    attr_reader :created_at

    # @return [Hash] Provider details — :class, :model, :host, :num_ctx, :read_timeout, :dimension
    attr_reader :embedding_provider

    # @return [Hash] Store types — :vector_store, :metadata_store, :graph_store (Symbols)
    attr_reader :stores

    # Parse a +woods.json+ hash into a {ResolvedConfig}.
    #
    # @param raw [Hash] Parsed JSON hash (string or symbol keys)
    # @return [ResolvedConfig]
    # @raise [Woods::MCP::UnsupportedArtifact] if schema_version is not supported
    def self.from_hash(raw)
      data = normalize_keys(raw)
      validate_schema_version!(data[:schema_version].to_i)

      new(
        schema_version: data[:schema_version].to_i,
        gem_version: data[:gem_version].to_s,
        created_at: parse_time(data[:created_at]),
        embedding_provider: parse_provider(data[:embedding_provider] || {}),
        stores: parse_stores(data[:stores] || {})
      )
    end

    # Capture the current {Woods::Configuration} as a {ResolvedConfig}.
    #
    # The +provider:+ kwarg lets callers pass a live embedding provider so
    # the dimension is discovered at runtime instead of being read from a
    # declared-only field. This matters for Ollama — dimensions come from
    # the model, not the config — and doesn't hurt OpenAI, whose provider
    # exposes the same +#dimensions+ interface.
    #
    # When +provider:+ is omitted, dimension falls back to
    # +config.embedding_options[:dimension]+ (useful for specs and for
    # offline ResolvedConfig construction where no provider exists).
    #
    # @param config [Woods::Configuration]
    # @param gem_version [String] Defaults to {Woods::VERSION}
    # @param provider [#dimensions, nil] Optional live provider to probe
    #   for dimension when +config.embedding_options[:dimension]+ is absent.
    # @return [ResolvedConfig]
    def self.from_configuration(config, gem_version: nil, provider: nil) # rubocop:disable Metrics/MethodLength,Metrics/AbcSize,Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity
      require_relative 'version'

      opts = config.embedding_options || {}
      declared_dim = opts[:dimension] || opts['dimension']
      dim = declared_dim || (provider.respond_to?(:dimensions) ? provider.dimensions : nil)

      provider_hash = {
        class: resolve_provider_class(config.embedding_provider),
        model: (opts[:model] || opts['model'] || config.embedding_model).to_s,
        dimension: dim.to_i,
        host: opts[:host] || opts['host'],
        num_ctx: opts[:num_ctx] || opts['num_ctx'],
        read_timeout: opts[:read_timeout] || opts['read_timeout']
      }.compact

      new(
        schema_version: SCHEMA_VERSION_SUPPORTED,
        gem_version: (gem_version || Woods::VERSION).to_s,
        created_at: Time.now.utc,
        embedding_provider: provider_hash,
        stores: {
          vector_store: config.vector_store,
          metadata_store: config.metadata_store,
          graph_store: config.graph_store
        }
      )
    end

    # @param schema_version [Integer]
    # @param gem_version [String]
    # @param created_at [Time]
    # @param embedding_provider [Hash]
    # @param stores [Hash]
    def initialize(schema_version:, gem_version:, created_at:, embedding_provider:, stores:)
      @schema_version = schema_version
      @gem_version = gem_version.to_s.freeze
      @created_at = created_at
      @embedding_provider = deep_freeze(embedding_provider)
      @stores = deep_freeze(stores)
      freeze
    end

    # @return [Integer] Embedding dimension declared by the provider
    def dimension
      embedding_provider[:dimension].to_i
    end

    # Short string identifying this provider configuration, useful for log
    # messages and {ConfigMismatch} error text.
    #
    # @return [String] e.g. "Ollama/nomic-embed-text@http://host.docker.internal:11434"
    def provider_signature
      klass = embedding_provider[:class].to_s.split('::').last
      model = embedding_provider[:model]
      host  = embedding_provider[:host]
      host ? "#{klass}/#{model}@#{host}" : "#{klass}/#{model}"
    end

    # Returns +true+ if +other+ uses the same provider class, model, dimension,
    # and store types. Ignores gem version, read_timeout, num_ctx, and created_at.
    #
    # @param other [ResolvedConfig]
    # @return [Boolean]
    def matches?(other)
      embedding_provider[:class] == other.embedding_provider[:class] &&
        embedding_provider[:model] == other.embedding_provider[:model] &&
        dimension == other.dimension &&
        stores[:vector_store] == other.stores[:vector_store] &&
        stores[:metadata_store] == other.stores[:metadata_store] &&
        stores[:graph_store] == other.stores[:graph_store]
    end

    # Assert that +stored_config+ (the config captured at embed time) is
    # compatible with +self+ (the live host config). Raises typed errors
    # so the operator can diagnose the mismatch without reading source.
    #
    # @param stored_config [ResolvedConfig]
    # @raise [Woods::MCP::DimensionMismatch] if dimensions differ
    # @raise [Woods::MCP::ConfigMismatch] if provider class or model differs
    # @return [void]
    def assert_compatible!(stored_config)
      assert_dimensions_match!(stored_config)
      assert_provider_matches!(stored_config)
    end

    # Serialize to a Hash suitable for +JSON.generate+ and round-trippable
    # through {.from_hash}.
    #
    # @return [Hash]
    def to_snapshot_json
      {
        'schema_version' => schema_version,
        'gem_version' => gem_version,
        'created_at' => created_at.iso8601,
        'embedding_provider' => embedding_provider.transform_keys(&:to_s),
        'stores' => stores.transform_keys(&:to_s).transform_values(&:to_s)
      }
    end

    # @return [Hash]
    def to_h
      to_snapshot_json.freeze
    end

    private

    # Recursively freeze a Hash and every Hash/Array/String it transitively
    # holds. The previous shallow `.freeze` left nested Hash values mutable
    # — a caller reaching `config.embedding_provider[:options][:foo] = …`
    # could mutate the supposedly-immutable snapshot. Public ResolvedConfig
    # is documented as a frozen Whole Value; this enforces it.
    def deep_freeze(obj) # rubocop:disable Metrics/CyclomaticComplexity
      case obj
      when Hash
        obj.each_pair do |k, v|
          deep_freeze(k)
          deep_freeze(v)
        end
        obj.frozen? ? obj : obj.freeze
      when Array
        obj.each { |v| deep_freeze(v) }
        obj.frozen? ? obj : obj.freeze
      when String
        # Freeze in place — returning a frozen dup would be discarded by the
        # Hash/Array branches above (they recurse for side effects only),
        # leaving every nested string mutable.
        obj.frozen? ? obj : obj.freeze
      else
        obj
      end
    end

    def assert_dimensions_match!(stored_config)
      return if dimension == stored_config.dimension

      raise Woods::MCP::DimensionMismatch.new(
        "Provider dimension #{dimension} does not match stored dimension #{stored_config.dimension}. " \
        'Re-run `rake woods:embed` to rebuild the index.',
        details: {
          expected: stored_config.dimension,
          actual: dimension,
          stored_at: stored_config.created_at.iso8601
        }
      )
    end

    def assert_provider_matches!(stored_config)
      return if embedding_provider[:class] == stored_config.embedding_provider[:class] &&
                embedding_provider[:model] == stored_config.embedding_provider[:model]

      raise Woods::MCP::ConfigMismatch.new(
        "Host provider #{provider_signature} does not match stored provider #{stored_config.provider_signature}. " \
        'Re-run `rake woods:embed` or align host configuration.',
        details: {
          host: provider_signature,
          stored: stored_config.provider_signature,
          stored_at: stored_config.created_at.iso8601
        }
      )
    end

    class << self
      private

      def validate_schema_version!(version)
        # Forwards-compatibility rule: accept any version at or below the
        # supported ceiling. An older dump (schema_version 1) must still
        # load cleanly on a newer gem (schema_version 2), matching the
        # behaviour of the binary snapshotters (vectors.bin, metadata.msgpack)
        # which both use `<=`.
        return if version.positive? && version <= SCHEMA_VERSION_SUPPORTED

        raise Woods::MCP::UnsupportedArtifact.new(
          "woods.json schema_version #{version} is not supported (supported: #{SCHEMA_VERSION_SUPPORTED})",
          details: { found: version, supported: SCHEMA_VERSION_SUPPORTED }
        )
      end

      def parse_provider(raw)
        data = normalize_keys(raw)
        {
          class: data[:class].to_s,
          model: data[:model].to_s,
          dimension: data[:dimension].to_i,
          host: data[:host],
          num_ctx: data[:num_ctx],
          read_timeout: data[:read_timeout]
        }.compact
      end

      def parse_stores(raw)
        data = normalize_keys(raw)
        {
          vector_store: data[:vector_store]&.to_sym,
          metadata_store: data[:metadata_store]&.to_sym,
          graph_store: data[:graph_store]&.to_sym
        }
      end

      def parse_time(value)
        value ? Time.parse(value.to_s) : Time.now.utc
      end

      def normalize_keys(hash)
        hash.transform_keys(&:to_sym)
      end

      def resolve_provider_class(provider)
        case provider
        when :openai then 'Woods::Embedding::Provider::OpenAI'
        when :ollama then 'Woods::Embedding::Provider::Ollama'
        when String  then provider
        when Class   then provider.name
        when nil     then ''
        else provider.to_s
        end
      end
    end
  end
end
