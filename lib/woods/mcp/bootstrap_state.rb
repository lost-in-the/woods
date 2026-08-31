# frozen_string_literal: true

require 'time'

module Woods
  module MCP
    # Tracks the lifecycle state of an MCP server bootstrap sequence.
    #
    # Status transitions flow forward: +initializing+ → +hydrating+ →
    # +hydrated+ (success path), or +initializing+/+hydrating+ → +degraded+
    # (provider unreachable) or +failed+ (config-invalid). States are mutated
    # via {#mark} so the +woods_status+ MCP tool always reads consistent values.
    #
    # @example Bootstrapper usage
    #   state = Woods::MCP::BootstrapState.new
    #   state.mark(:hydrating)
    #   vector_store = Snapshotter::Vector.load_or_empty(artifact)
    #   state.mark(:hydrated)
    #   # or, on provider failure:
    #   state.mark(:degraded, reason: ProviderUnreachable.new("..."))
    #
    class BootstrapState
      VALID_STATUSES = %i[initializing hydrating hydrated degraded failed].freeze

      # @return [Symbol] one of +:initializing+, +:hydrating+, +:hydrated+,
      #   +:degraded+, +:failed+
      attr_reader :status

      # @return [Exception, nil] the exception that caused degradation or failure
      attr_reader :reason

      # @return [Time, nil] set when status transitions to +:hydrated+
      attr_reader :hydrated_at

      # @return [Time, nil] set when status transitions to +:degraded+
      attr_reader :degraded_since

      # @return [Woods::ResolvedConfig, nil] captured at embed time and read
      #   back from +woods.json+ during boot. Used by +woods_status+ to report
      #   the provider/model actually in play instead of the stale defaults on
      #   {Woods.configuration}.
      attr_accessor :resolved_config

      # Store-hydration soft failures recorded during boot, keyed by store
      # component (+:vector+, +:metadata+, +:graph+) with the exception that
      # caused each. A recorded failure leaves the retriever serving empty
      # stores; {#hydration_failed?} is the signal +woods_status+ and
      # +codebase_retrieve+ use to stop presenting that as healthy (M6).
      attr_reader :hydration_failures

      # Reload-phase degraded condition (M7), or +nil+. Shape:
      # +{ phase: 'reload', generation:, stores:, reason: }+ — the generation
      # still being served, the store component(s) whose refresh failed, and
      # the formatted reason. Deliberately separate from {#hydration_failures}
      # and from +status+: a failed reload leaves the PREVIOUS fully aligned
      # generation being served, so the boot degraded state must not flip and
      # +codebase_retrieve+ must keep answering from the still-healthy old
      # stores. +woods_status+ exposes this additively; a successful reload
      # clears it.
      attr_reader :reload_failure

      def initialize
        @status = :initializing
        @reason = nil
        @hydrated_at = nil
        @degraded_since = nil
        @resolved_config = nil
        @hydration_failures = {}
        @reload_failure = nil
      end

      # Record a store-hydration soft failure. Kept separately from {#reason}
      # so a provider-unreachable degradation and a hydration degradation can
      # coexist without overwriting each other's evidence.
      #
      # @param component [Symbol, String] which store failed to hydrate
      # @param error [Exception] the rescued hydration error
      # @return [self]
      def record_hydration_failure(component, error)
        @hydration_failures[component.to_sym] = error
        self
      end

      # Did any store fail to hydrate at boot?
      #
      # @return [Boolean]
      def hydration_failed?
        !@hydration_failures.empty?
      end

      # Record a failed reload attempt (M7). The reload transaction is
      # all-or-nothing: the failure means the previous generation is still
      # being served, which is what +generation+ names.
      #
      # @param generation [Integer] generation still being served
      # @param stores [Array<Symbol, String>] store component(s) whose
      #   refresh failed
      # @param reason [String] formatted failure reason (+Class: message+)
      # @return [self]
      def record_reload_failure(generation:, stores:, reason:)
        @reload_failure = {
          phase: 'reload',
          generation: generation,
          stores: Array(stores).map(&:to_s),
          reason: reason
        }
        self
      end

      # Clear the reload-phase degraded condition after a successful reload.
      #
      # @return [self]
      def clear_reload_failure!
        @reload_failure = nil
        self
      end

      # Did the most recent reload attempt fail? Cleared by the next success.
      #
      # @return [Boolean]
      def reload_failed?
        !@reload_failure.nil?
      end

      # Transition to a new status.
      #
      # +hydrated_at+ is recorded on +:hydrated+; +degraded_since+ is recorded
      # on +:degraded+. +reason:+ is accepted for +:degraded+ and +:failed+.
      #
      # @param new_status [Symbol] target status (must be in {VALID_STATUSES})
      # @param reason [Exception, nil] causal exception for degraded/failed states
      # @param now [Time] timestamp for the transition (default: UTC now)
      # @return [self]
      # @raise [ArgumentError] when +new_status+ is not a recognised status
      def mark(new_status, reason: nil, now: Time.now.utc)
        unless VALID_STATUSES.include?(new_status)
          raise ArgumentError,
                "Unknown status #{new_status.inspect}. " \
                "Must be one of: #{VALID_STATUSES.map(&:inspect).join(', ')}"
        end

        @status = new_status
        @reason = reason

        case new_status
        when :hydrated
          @hydrated_at = now
        when :degraded
          @degraded_since = now
        end

        self
      end

      # Returns a hash suitable for embedding in a +woods_status+ MCP response.
      #
      # @return [Hash]
      def to_h
        h = { status: @status }
        h[:reason] = "#{@reason.class}: #{@reason.message}" if @reason
        h[:hydrated_at] = @hydrated_at.iso8601 if @hydrated_at
        h[:degraded_since] = @degraded_since.iso8601 if @degraded_since
        if hydration_failed?
          h[:hydration_failures] = @hydration_failures.transform_values { |e| "#{e.class}: #{e.message}" }
        end
        h[:reload_failure] = @reload_failure.dup if @reload_failure
        h
      end
    end
  end
end
