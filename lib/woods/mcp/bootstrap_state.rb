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

      def initialize
        @status = :initializing
        @reason = nil
        @hydrated_at = nil
        @degraded_since = nil
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
        h
      end
    end
  end
end
