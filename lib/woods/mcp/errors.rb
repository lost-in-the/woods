# frozen_string_literal: true

require_relative '../storage/inapplicable_backend'

module Woods
  module MCP
    # Base class for all bootstrap-time failures in the MCP server.
    #
    # Inherits directly from {Woods::Error} — a sibling of {Woods::ConfigurationError},
    # not a child. Artifact/runtime state errors grouped here do not describe
    # declared-configuration problems, so grouping under ConfigurationError would
    # mislead host apps that rescue it.
    #
    # Each subclass carries a +details+ hash with structured context for operator
    # messages. The +exe/woods-mcp+ top-level rescue formats this into a one-line
    # hint.
    #
    # @example Rescue in an MCP entry point
    #   rescue Woods::MCP::BootstrapError => e
    #     warn "woods-mcp: #{e.class}: #{e.message}"
    #     exit 2
    class BootstrapError < Woods::Error
      # @return [Hash] Structured context for operator diagnostics
      attr_reader :details

      # @param message [String]
      # @param details [Hash] Structured context (artifact paths, versions, etc.)
      def initialize(message = nil, details: {})
        super(message)
        @details = details
      end
    end

    # Raised when a required credential (e.g. OpenAI API key) is absent and
    # cannot be resolved from the config snapshot or environment.
    #
    # @example
    #   raise Woods::MCP::MissingCredential.new(
    #     "OPENAI_API_KEY is required for OpenAI provider",
    #     details: { credential: "OPENAI_API_KEY", provider: "openai" }
    #   )
    class MissingCredential < BootstrapError; end

    # Raised when a stored config snapshot contradicts the active host config
    # in a way that cannot be reconciled (e.g. provider class mismatch).
    #
    # @example
    #   raise Woods::MCP::ConfigMismatch.new(
    #     "Stored config uses Ollama but host config specifies OpenAI",
    #     details: { stored: "Ollama", host: "OpenAI" }
    #   )
    class ConfigMismatch < BootstrapError; end

    # Raised when the dimension recorded in the config snapshot or vector dump
    # does not match the dimension reported by the active embedding provider.
    #
    # @example
    #   raise Woods::MCP::DimensionMismatch.new(
    #     "Provider dimension 1536 does not match stored dimension 768",
    #     details: { expected: 768, actual: 1536 }
    #   )
    class DimensionMismatch < BootstrapError; end

    # Raised when the +schema_version+ in +woods.json+ or a dump file is
    # newer than the maximum version this gem release supports, or when the
    # artifact header is corrupted and cannot be parsed.
    #
    # @example
    #   raise Woods::MCP::UnsupportedArtifact.new(
    #     "woods.json schema_version 3 > supported max 1",
    #     details: { artifact_version: 3, max_supported: 1, path: config_path.to_s }
    #   )
    class UnsupportedArtifact < BootstrapError; end

    # Raised when +woods.json+ is absent from +output_dir+ and the operator has
    # opted into strict mode with +WOODS_REQUIRE_INDEX=1+. By default an absent
    # artifact is *not* an error — the server boots in pattern/structural-only
    # mode (see {ConfigResolver.resolve_without_artifact}). Strict mode exists
    # for deployments that want to fail closed when an index is missing.
    #
    # @example
    #   raise Woods::MCP::MissingArtifact.new(
    #     "No woods.json found in /app/tmp/woods. Run `rake woods:embed` first.",
    #     details: { output_dir: "/app/tmp/woods" }
    #   )
    class MissingArtifact < BootstrapError; end

    # Raised when the configured embedding provider cannot be reached at boot.
    # This is a **recoverable** sibling of {BootstrapError} — it is deliberately
    # outside the BootstrapError hierarchy because the MCP server starts degraded
    # and retries on first query rather than refusing to start.
    #
    # {Bootstrapper} catches this internally; nothing upstream should rescue it.
    #
    # @example
    #   raise Woods::MCP::ProviderUnreachable.new(
    #     "http://host.docker.internal:11434 refused connection",
    #     details: { url: "http://host.docker.internal:11434", reason: "connection refused" }
    #   )
    class ProviderUnreachable < Woods::Error
      # @return [String] URL that was probed
      attr_reader :url
      # @return [String] Machine-readable failure reason (e.g. "connection_refused",
      #   "timeout", "http_500", "unauthorized", "dns_failure")
      attr_reader :reason
      # @return [Hash] Structured context forwarded to operators for diagnosis
      attr_reader :details

      # Supports two call styles:
      #
      #   Woods::MCP::ProviderUnreachable.new(url: "http://...", reason: "timeout")
      #   Woods::MCP::ProviderUnreachable.new("message", details: { ... })
      #
      # The kwarg form is preferred — probes have url/reason in hand and the
      # message is derived. The positional form exists for callers that
      # already have a formatted message.
      def initialize(message = nil, url: nil, reason: nil, details: {})
        @url = url || details[:url] || details['url']
        @reason = reason || details[:reason] || details['reason']
        @details = details.dup
        @details[:url] = @url if @url && !@details.key?(:url) && !@details.key?('url')
        @details[:reason] = @reason if @reason && !@details.key?(:reason) && !@details.key?('reason')
        super(message || default_message)
      end

      private

      def default_message
        return "#{@url}: #{@reason}" if @url && @reason
        return "provider unreachable (#{@reason})" if @reason

        'provider unreachable'
      end
    end

    # Raised when an MCP +reload+ transaction cannot complete (M7). Deliberately
    # a sibling of {BootstrapError}, not a child: this describes a runtime
    # reload attempt, not boot state. The transaction is all-or-nothing —
    # when this is raised, the reader caches and the retriever's store bundle
    # were NOT touched and the previous generation is still being served.
    #
    # The exception carries the payload of the reload-phase degraded condition:
    # the generation still being served, and the store component(s) whose
    # refresh failed. The +reload+ tool maps it to a +degraded_index+ tool
    # error with +phase: 'reload'+, and {BootstrapState#record_reload_failure}
    # persists the same shape for +woods_status+.
    #
    # @example Raising from the reload transaction
    #   raise Woods::MCP::ReloadDegraded.new(
    #     "vector hydration failed: IOError: dump vanished",
    #     generation: served_marker.number, stores: [:vector], error: e
    #   )
    class ReloadDegraded < Woods::Error
      # @return [Integer] the generation number still being served
      attr_reader :generation

      # @return [Array<String>] store component(s) whose refresh failed
      #   (subset of +vector+, +metadata+, +graph+; all three when the
      #   failure is not attributable to one component)
      attr_reader :stores

      # @return [Exception, nil] the underlying error, when the failure was
      #   caused by one
      attr_reader :cause_error

      # @param message [String]
      # @param generation [Integer] generation still being served
      # @param stores [Array<Symbol, String>] failing store component(s)
      # @param error [Exception, nil] underlying cause
      def initialize(message, generation:, stores:, error: nil)
        super(message)
        @generation = generation
        @stores = Array(stores).map(&:to_s)
        @cause_error = error
      end
    end

    # The generation recheck inside a reload transaction failed: the on-disk
    # generation moved while candidate stores were being built off-side, so
    # the built bundle is stale. Swapping it would pair reader state from one
    # generation with stores from another. Nothing is swapped; the next
    # +reload+ invocation is the recovery path (it rebuilds candidates
    # against the fresh generation).
    class ReloadGenerationMoved < ReloadDegraded; end
  end
end
