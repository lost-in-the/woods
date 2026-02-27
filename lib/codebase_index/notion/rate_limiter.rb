# frozen_string_literal: true

module CodebaseIndex
  module Notion
    # Thread-safe rate limiter for Notion API (3 requests/second default).
    #
    # Enforces a minimum interval between API calls by sleeping when necessary.
    # Uses a Mutex to ensure thread safety when called from concurrent contexts.
    #
    # @example
    #   limiter = RateLimiter.new(requests_per_second: 3)
    #   limiter.throttle { client.create_page(...) }
    #   limiter.throttle { client.update_page(...) }
    #
    class RateLimiter
      # @param requests_per_second [Numeric] Maximum requests per second (default: 3)
      # @raise [ArgumentError] if requests_per_second is not positive
      def initialize(requests_per_second: 3)
        unless requests_per_second.is_a?(Numeric) && requests_per_second.positive?
          raise ArgumentError, "requests_per_second must be positive, got #{requests_per_second.inspect}"
        end

        @min_interval = 1.0 / requests_per_second
        @last_request_at = nil
        @mutex = Mutex.new
      end

      # Execute a block after enforcing the rate limit.
      #
      # Sleeps if the minimum interval since the last request hasn't elapsed.
      # Thread-safe — only one request proceeds at a time.
      #
      # @yield The block to execute after rate limiting
      # @return [Object] The block's return value
      # @raise [ArgumentError] if no block is given
      def throttle
        raise ArgumentError, 'block required' unless block_given?

        @mutex.synchronize do
          wait_for_interval
        end

        result = yield

        @mutex.synchronize do
          @last_request_at = monotonic_now
        end

        result
      end

      private

      # Sleep if minimum interval hasn't elapsed since last request.
      #
      # @return [void]
      def wait_for_interval
        return unless @last_request_at

        elapsed = monotonic_now - @last_request_at
        remaining = @min_interval - elapsed
        sleep(remaining) if remaining.positive?
      end

      # Monotonic clock for accurate interval measurement.
      #
      # @return [Float] Current monotonic time in seconds
      def monotonic_now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
