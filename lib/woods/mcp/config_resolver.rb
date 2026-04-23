# frozen_string_literal: true

require_relative 'errors'
require_relative '../resolved_config'

module Woods
  module MCP
    # Resolves the embedding configuration that the MCP server should use.
    #
    # Reads +woods.json+ (the resolved config snapshot written at embed time),
    # applies environment-variable overrides, validates, and returns either a
    # populated {Woods::Configuration} or raises a typed {BootstrapError}
    # subclass that the caller can present to an operator.
    #
    # This class is extracted from {Bootstrapper} to isolate the
    # config-resolution concern from network probing and store construction.
    # {Bootstrapper} delegates to {.resolve} as its first step.
    #
    # Resolution order (highest priority first):
    #
    # 1. Host Rails initializer (Woods.configuration already has embedding_provider).
    #    When +woods.json+ is also present the stored config is loaded and asserted
    #    compatible via {ResolvedConfig#assert_compatible!}.
    # 2. +woods.json+ snapshot alone (MCP server running without a host initializer).
    #    The stored config is used to populate +config+ in place.
    # 3. Environment-variable auto-detect (deprecated, opt-in via
    #    +WOODS_ALLOW_AUTODETECT=1+). Mutates +config+ to set provider and stores.
    # 4. If none of the above applies, raises {MissingArtifact}.
    #
    # @example Typical Bootstrapper usage
    #   config, source = ConfigResolver.resolve(Woods.configuration, artifact: artifact)
    #   # config.embedding_provider is now guaranteed to be non-nil (or :none was returned)
    #
    module ConfigResolver
      # Resolve and validate the embedding configuration.
      #
      # When +woods.json+ is present in the artifact directory it is parsed into
      # a {ResolvedConfig} and, if the host already has a provider configured,
      # validated for compatibility (dimension + provider class/model must agree).
      # If the host has no provider configured the stored config is applied to
      # +config+ so {Builder} can construct the correct provider.
      #
      # When +woods.json+ is absent and the host already has a provider
      # configured, the host config is trusted and used as-is.
      #
      # When +woods.json+ is absent and the host has no provider configured:
      # - If +WOODS_ALLOW_AUTODETECT+ is +1+, falls through to env-var
      #   auto-detect (deprecated, emits a structured warning).
      # - Otherwise raises {MissingArtifact}.
      #
      # @param config [Woods::Configuration] the live host configuration object.
      #   May be mutated in the auto-detect path.
      # @param artifact [Woods::IndexArtifact, nil] the on-disk artifact wrapper.
      # @param env [Hash] environment variable source (default +ENV+, overridable
      #   in specs without stubbing the global ENV).
      # @param ollama_probe [#call, nil] callable used to check Ollama reachability
      #   in the deprecated auto-detect path. Defaults to {.ollama_reachable?} on
      #   this module. Callers may pass a different probe to facilitate testing
      #   without touching global state.
      # @return [Array(Woods::Configuration, Symbol)] tuple of +[config, source]+
      #   where +source+ is one of +:snapshot+, +:host_config+, +:autodetect+,
      #   or +:none+. The config is the same object passed in, possibly mutated.
      # @raise [Woods::MCP::MissingArtifact] when +woods.json+ is absent, the
      #   host has no provider configured, and +WOODS_ALLOW_AUTODETECT+ is unset.
      # @raise [Woods::MCP::UnsupportedArtifact] when +woods.json+ has an
      #   unsupported +schema_version+.
      # @raise [Woods::MCP::DimensionMismatch] when stored and live provider
      #   dimensions disagree.
      # @raise [Woods::MCP::ConfigMismatch] when stored and live provider
      #   class/model disagree.
      def self.resolve(config, artifact:, env: ENV, ollama_probe: nil)
        stored = read_stored_config(artifact)

        if stored
          [apply_stored_config(config, stored, artifact: artifact, env: env), :snapshot]
        elsif config.embedding_provider
          # Host initializer configured a provider; no woods.json to validate
          # against. Trust the host config and proceed.
          [config, :host_config]
        else
          resolve_without_artifact(config, artifact: artifact, env: env, ollama_probe: ollama_probe)
        end
      end

      # Read and parse +woods.json+ if it exists.
      #
      # @param artifact [Woods::IndexArtifact, nil]
      # @return [Woods::ResolvedConfig, nil]
      # @raise [Woods::MCP::UnsupportedArtifact] if the file has an unsupported
      #   schema version.
      def self.read_stored_config(artifact)
        return nil unless artifact&.config_path&.exist?

        raw = artifact.read_config
        return nil unless raw

        ResolvedConfig.from_hash(raw)
      end
      private_class_method :read_stored_config

      # Reconcile the live host config against a stored {ResolvedConfig}.
      #
      # When the host has an +embedding_provider+ configured, assert that it
      # matches the stored config. When the host has no provider configured,
      # populate +config+ from the stored values so {Builder} can construct
      # the correct provider.
      #
      # @param config [Woods::Configuration]
      # @param stored [Woods::ResolvedConfig]
      # @param artifact [Woods::IndexArtifact]
      # @return [Woods::Configuration]
      def self.apply_stored_config(config, stored, artifact:, env: ENV)
        if config.embedding_provider
          live = live_resolved_config(config)
          live.assert_compatible!(stored)
          config
        else
          populate_from_stored(config, stored, artifact: artifact, env: env)
        end
      end
      private_class_method :apply_stored_config

      # Build a ResolvedConfig from the live host config, probing the
      # provider's dimension when possible. Tolerant of probe failures
      # (unreachable Ollama): falls back to the declared-only path so
      # {ResolvedConfig#assert_compatible!} surfaces a typed
      # {DimensionMismatch} instead of a raw +Errno::ECONNREFUSED+
      # escaping the caller's {BootstrapError} rescue.
      def self.live_resolved_config(config)
        require_relative '../builder'
        provider = Woods::Builder.new(config).build_embedding_provider
        ResolvedConfig.from_configuration(config, provider: provider)
      rescue StandardError
        ResolvedConfig.from_configuration(config)
      end
      private_class_method :live_resolved_config

      # Populate a blank {Woods::Configuration} from a stored {ResolvedConfig}.
      #
      # Maps the serialised provider class name back to the +:ollama+ /
      # +:openai+ symbol that {Builder} expects, and restores store types.
      # Applied when an MCP server starts without a host Rails initializer.
      #
      # @param config [Woods::Configuration]
      # @param stored [Woods::ResolvedConfig]
      # @param artifact [Woods::IndexArtifact]
      # @return [Woods::Configuration]
      def self.populate_from_stored(config, stored, artifact:, env: ENV)
        config.vector_store = stored.stores[:vector_store] || :in_memory
        config.metadata_store = stored.stores[:metadata_store] || :in_memory
        config.graph_store = stored.stores[:graph_store] || :in_memory
        provider_sym = provider_symbol(stored.embedding_provider[:class])
        config.embedding_provider = provider_sym

        opts = {}
        opts[:model] = stored.embedding_provider[:model] if stored.embedding_provider[:model]
        opts[:host] = stored.embedding_provider[:host] if stored.embedding_provider[:host]
        opts[:num_ctx] = stored.embedding_provider[:num_ctx] if stored.embedding_provider[:num_ctx]
        opts[:read_timeout] = stored.embedding_provider[:read_timeout] if stored.embedding_provider[:read_timeout]
        opts[:dimension] = stored.embedding_provider[:dimension] if stored.embedding_provider[:dimension]&.positive?

        # OpenAI needs an api_key to construct. `woods.json` deliberately
        # never stores credentials; pull from env here so the standalone
        # MCP server can boot against an OpenAI-embedded index. Raise a
        # typed error if the env var is missing — previously the generic
        # ArgumentError from OpenAI.new(**opts) wasn't a BootstrapError
        # and the top-level rescue in exe/woods-mcp wouldn't catch it.
        if provider_sym == :openai
          api_key = env.fetch('OPENAI_API_KEY', nil)
          if api_key.nil? || api_key.empty?
            raise Woods::MCP::MissingCredential.new(
              'woods.json says the index was embedded with OpenAI but OPENAI_API_KEY is unset. ' \
              'Export the key before starting the MCP server, or re-embed with a different provider.',
              details: { provider: 'openai', missing_env_var: 'OPENAI_API_KEY' }
            )
          end

          opts[:api_key] = api_key
        end

        config.embedding_options = opts unless opts.empty?

        warn "[woods-mcp] config_source: loaded from woods.json (#{artifact.config_path})"
        config
      end
      private_class_method :populate_from_stored

      # Convert a fully-qualified provider class name back to the symbol
      # that {Builder} understands.
      #
      # @param class_name [String]
      # @return [Symbol, String] symbol for known providers, raw string otherwise
      def self.provider_symbol(class_name)
        case class_name.to_s
        when /Ollama/ then :ollama
        when /OpenAI/ then :openai
        else class_name.to_s
        end
      end
      private_class_method :provider_symbol

      # Handle the no-artifact, no-host-provider case.
      #
      # Raises {MissingArtifact} unless +WOODS_ALLOW_AUTODETECT=1+ opts in to
      # the deprecated env-var auto-detect path.
      #
      # @param config [Woods::Configuration]
      # @param artifact [Woods::IndexArtifact, nil]
      # @param env [Hash]
      # @param ollama_probe [#call, nil]
      # @return [Woods::Configuration]
      # @raise [Woods::MCP::MissingArtifact]
      def self.resolve_without_artifact(config, artifact:, env:, ollama_probe:)
        if env['WOODS_ALLOW_AUTODETECT'] != '1'
          raise MissingArtifact.new(
            'No woods.json found and WOODS_ALLOW_AUTODETECT is unset. ' \
            'Run `bundle exec rake woods:extract` in your host app, or set ' \
            'WOODS_ALLOW_AUTODETECT=1 to probe env vars (deprecated).',
            details: { output_dir: artifact&.output_dir&.to_s }
          )
        end

        warn '[woods-mcp] deprecated_autodetect: falling back to env-var auto-detect (no woods.json found)'
        [autodetect_from_env(config, env: env, ollama_probe: ollama_probe), :autodetect]
      end
      private_class_method :resolve_without_artifact

      # Probe environment variables for provider credentials and configure
      # +config+ accordingly.
      #
      # Only reachable when +WOODS_ALLOW_AUTODETECT=1+ and no +woods.json+
      # is present. Mutates +config+ to set provider and stores when a
      # credential or reachable Ollama instance is found.
      #
      # @param config [Woods::Configuration]
      # @param env [Hash]
      # @param ollama_probe [#call, nil] callable for Ollama reachability check;
      #   defaults to {.ollama_reachable?} on this module when nil.
      # @return [Woods::Configuration]
      def self.autodetect_from_env(config, env:, ollama_probe:)
        probe = ollama_probe || method(:ollama_reachable?)
        openai_key = env.fetch('OPENAI_API_KEY', nil)
        if openai_key
          config.vector_store = :in_memory
          config.metadata_store = :in_memory
          config.graph_store = :in_memory
          config.embedding_provider = :openai
          config.embedding_options = { api_key: openai_key }
        elsif probe.call
          config.vector_store = :in_memory
          config.metadata_store = :in_memory
          config.graph_store = :in_memory
          config.embedding_provider = :ollama
          config.embedding_options = {
            host: env.fetch('OLLAMA_BASE_URL', 'http://localhost:11434'),
            model: env.fetch('OLLAMA_EMBED_MODEL', 'nomic-embed-text')
          }
        end

        config
      end
      private_class_method :autodetect_from_env

      # Check whether Ollama is reachable at the configured base URL.
      #
      # Used as the default probe in the deprecated auto-detect path. Callers
      # may inject a different probe via +ollama_probe:+ kwarg.
      #
      # @return [Boolean]
      def self.ollama_reachable?
        require 'net/http'
        require 'uri'

        base_url = ENV.fetch('OLLAMA_BASE_URL', 'http://localhost:11434')
        uri = URI.parse(base_url)
        Net::HTTP.start(uri.host, uri.port,
                        open_timeout: 0.5, read_timeout: 0.5,
                        use_ssl: uri.scheme == 'https') do |http|
          response = http.get('/api/tags')
          !response.is_a?(Net::HTTPServerError)
        end
      rescue StandardError
        false
      end
      private_class_method :ollama_reachable?
    end
  end
end
