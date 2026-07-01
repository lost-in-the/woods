# frozen_string_literal: true

module Woods
  module Resilience
    # Raised when the circuit breaker is open and calls are being rejected.
    #
    # @example Handling a circuit open condition
    #   begin
    #     breaker.call { provider.embed(text) }
    #   rescue CircuitOpenError => e
    #     use_cached_result(text)
    #   end
    class CircuitOpenError < Woods::Error; end

    # Circuit breaker pattern for protecting external service calls.
    #
    # Tracks failures and transitions between three states:
    # - **:closed** — normal operation, calls pass through
    # - **:open** — too many failures, calls are rejected immediately
    # - **:half_open** — testing recovery, one call is allowed through
    #
    # @example Basic usage
    #   breaker = CircuitBreaker.new(threshold: 5, reset_timeout: 60)
    #   result = breaker.call { external_service.request }
    #
    # @example With retry logic
    #   breaker = CircuitBreaker.new(threshold: 3, reset_timeout: 30)
    #   begin
    #     breaker.call { api.embed(text) }
    #   rescue CircuitOpenError
    #     # Service is down, use fallback
    #   end
    class CircuitBreaker
      # @return [Symbol] Current state — :closed, :open, or :half_open
      attr_reader :state

      # @param threshold [Integer] Number of consecutive failures before opening the circuit
      # @param reset_timeout [Numeric] Seconds to wait before transitioning from open to half_open
      # @param success_threshold [Integer] Number of consecutive successful probes required to
      #   close the circuit from half_open (default 1). Higher values reduce flapping when a
      #   recovering service is still intermittently failing.
      def initialize(threshold: 5, reset_timeout: 60, success_threshold: 1)
        @threshold = threshold
        @reset_timeout = reset_timeout
        @success_threshold = success_threshold
        @state = :closed
        @failure_count = 0
        @success_count = 0
        @last_failure_time = nil
        @half_open_probe_in_flight = false
        @mutex = Mutex.new
      end

      # Execute a block through the circuit breaker.
      #
      # In half_open, only a SINGLE probe is admitted at a time: concurrent
      # calls are rejected with {CircuitOpenError} until the probe resolves.
      # This prevents a thundering herd of probes against a still-recovering
      # service, and — because probes can't overlap — removes the race where a
      # slow probe's success would wipe failures recorded by a concurrent one.
      #
      # @yield The block to execute
      # @return [Object] The return value of the block
      # @raise [CircuitOpenError] if the circuit is open, or half_open with a probe already in flight
      # @raise [StandardError] re-raises any error from the block
      def call(&block)
        probing = admit_call!

        begin
          result = block.call
        rescue CircuitOpenError
          # A nested breaker tripped — release our probe slot but don't count
          # it as this breaker's own failure.
          @mutex.synchronize { @half_open_probe_in_flight = false if probing }
          raise
        rescue StandardError => e
          @mutex.synchronize do
            @half_open_probe_in_flight = false if probing
            record_failure
          end
          raise e
        end

        @mutex.synchronize do
          @half_open_probe_in_flight = false if probing
          record_success
        end
        result
      end

      private

      # Decide whether this call may proceed, transitioning open→half_open when
      # the reset timeout has elapsed. Runs entirely under the mutex.
      #
      # @return [Boolean] true when this call is the half_open probe (so the
      #   caller knows to release the probe slot when it finishes)
      # @raise [CircuitOpenError] when the circuit is open, or half_open with a
      #   probe already in flight
      def admit_call!
        @mutex.synchronize do
          case @state
          when :open
            raise CircuitOpenError, "Circuit breaker is open (#{@failure_count} failures)" unless reset_timeout_elapsed?

            # First caller after the timeout becomes the single half_open probe.
            @state = :half_open
            @half_open_probe_in_flight = true
            true
          when :half_open
            raise CircuitOpenError, 'Circuit breaker is half-open (probe in flight)' if @half_open_probe_in_flight

            @half_open_probe_in_flight = true
            true
          else
            false
          end
        end
      end

      # @return [Boolean] whether enough time has passed since the last failure
      #   to attempt a recovery probe
      def reset_timeout_elapsed?
        @last_failure_time && (monotonic_now - @last_failure_time >= @reset_timeout)
      end

      # Monotonic clock reading — immune to NTP slews and DST adjustments.
      #
      # @return [Float] seconds from an unspecified epoch.
      def monotonic_now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      # Record a failure and potentially open the circuit. A failure while
      # half_open reopens immediately, regardless of the failure threshold.
      def record_failure
        @failure_count += 1
        @last_failure_time = monotonic_now
        @success_count = 0
        @state = :open if @state == :half_open || @failure_count >= @threshold
      end

      # Record a success. In half_open, close only after enough consecutive
      # successful probes; in closed, a success clears accumulated failures.
      def record_success
        if @state == :half_open
          @success_count += 1
          reset! if @success_count >= @success_threshold
        else
          @failure_count = 0
        end
      end

      # Reset the circuit breaker to closed state with zero failures.
      def reset!
        @state = :closed
        @failure_count = 0
        @success_count = 0
        @last_failure_time = nil
        @half_open_probe_in_flight = false
      end
    end
  end
end
