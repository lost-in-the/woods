# frozen_string_literal: true

module CodebaseIndex
  module Resilience
    # Raised when the circuit breaker is open and calls are being rejected.
    #
    # @example Handling a circuit open condition
    #   begin
    #     breaker.call { provider.embed(text) }
    #   rescue CircuitOpenError => e
    #     use_cached_result(text)
    #   end
    class CircuitOpenError < CodebaseIndex::Error; end

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
      def initialize(threshold: 5, reset_timeout: 60)
        @threshold = threshold
        @reset_timeout = reset_timeout
        @state = :closed
        @failure_count = 0
        @last_failure_time = nil
        @mutex = Mutex.new
      end

      # Execute a block through the circuit breaker.
      #
      # @yield The block to execute
      # @return [Object] The return value of the block
      # @raise [CircuitOpenError] if the circuit is open and the timeout has not elapsed
      # @raise [StandardError] re-raises any error from the block
      def call(&block)
        @mutex.synchronize do
          case @state
          when :closed
            execute_closed(&block)
          when :open
            try_half_open(&block)
          when :half_open
            execute_half_open(&block)
          end
        end
      end

      private

      # Execute in closed state. Record failures; open circuit at threshold.
      #
      # @yield The block to execute
      # @return [Object] The return value of the block
      def execute_closed(&block)
        result = block.call
        reset!
        result
      rescue StandardError => e
        record_failure
        raise e
      end

      # Attempt transition from open to half_open if timeout has elapsed.
      #
      # @yield The block to execute if transitioning to half_open
      # @return [Object] The return value of the block
      # @raise [CircuitOpenError] if the timeout has not elapsed
      def try_half_open(&block)
        unless Time.now - @last_failure_time >= @reset_timeout
          raise CircuitOpenError, "Circuit breaker is open (#{@failure_count} failures)"
        end

        @state = :half_open
        execute_half_open(&block)
      end

      # Execute in half_open state. Reset on success; re-open on failure.
      #
      # @yield The block to execute
      # @return [Object] The return value of the block
      def execute_half_open(&block)
        result = block.call
        reset!
        result
      rescue StandardError => e
        @state = :open
        @last_failure_time = Time.now
        raise e
      end

      # Record a failure and potentially open the circuit.
      def record_failure
        @failure_count += 1
        @last_failure_time = Time.now
        @state = :open if @failure_count >= @threshold
      end

      # Reset the circuit breaker to closed state with zero failures.
      def reset!
        @state = :closed
        @failure_count = 0
        @last_failure_time = nil
      end
    end
  end
end
