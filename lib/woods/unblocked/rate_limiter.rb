# frozen_string_literal: true

require 'woods'

module Woods
  module Unblocked
    # Raised when the daily API call budget is exhausted. Subclasses
    # Woods::Error so existing +rescue Woods::Error+ sites keep working;
    # callers that need to branch on exhaustion rescue this class instead of
    # matching the message string.
    class BudgetExhaustedError < Woods::Error; end

    # Call-count budget for the Unblocked API, enforced **per run**.
    #
    # Unlike Notion's per-second throttling, Unblocked limits by daily call
    # count (1000/day). This limiter is a guard rail against a single run
    # burning that allowance, not a reimplementation of it: the counter lives
    # in the process and starts at zero every run.
    #
    # That is deliberate rather than an oversight. The real budget is enforced
    # server-side against the token, and the token is typically shared across
    # developer machines and CI runners with no common disk — so a persisted
    # local counter would be wrong in both directions (blocking a fresh run
    # that had allowance left, and permitting a run after the allowance was
    # spent elsewhere) while looking authoritative. A per-run cap gives the
    # useful half of the guarantee honestly.
    #
    # Messages therefore say "per run", and the operator is pointed at the
    # server-side limit for the real answer.
    #
    # @example
    #   limiter = RateLimiter.new(daily_budget: 1000)
    #   limiter.track { client.put_document(...) }  # => result
    #   limiter.remaining                            # => 999
    #
    class RateLimiter
      DEFAULT_BUDGET = 1000
      WARN_THRESHOLD = 0.8 # Warn at 80% usage

      # @param daily_budget [Integer] Maximum API calls per day
      # @param warn_io [IO] Where to write warnings (default: $stderr)
      def initialize(daily_budget: DEFAULT_BUDGET, warn_io: $stderr)
        unless daily_budget.is_a?(Integer) && daily_budget.positive?
          raise ArgumentError, 'daily_budget must be positive'
        end

        @daily_budget = daily_budget
        @calls_today = 0
        @warn_io = warn_io
        @warned = false
        @mutex = Mutex.new
      end

      # Execute a block, tracking the API call against the daily budget.
      #
      # @yield The API call to execute
      # @return [Object] The block's return value
      # @raise [BudgetExhaustedError] if daily budget is exhausted
      def track
        raise ArgumentError, 'block required' unless block_given?

        @mutex.synchronize do
          if @calls_today >= @daily_budget
            raise BudgetExhaustedError,
                  "Unblocked API call budget exhausted for this run (#{@daily_budget} calls). " \
                  'This is a per-run cap, not a reading of your remaining daily allowance — ' \
                  'the 1000/day limit is enforced server-side against your token and resets ' \
                  'at midnight PST. Raise or lower the per-run cap with UNBLOCKED_DAILY_BUDGET.'
          end

          @calls_today += 1
          warn_if_approaching_limit
        end

        yield
      end

      # Number of API calls remaining in this run's budget.
      #
      # @return [Integer]
      def remaining
        @daily_budget - @calls_today
      end

      # Number of API calls used today.
      #
      # @return [Integer]
      def used
        @calls_today
      end

      # Reset the daily counter (for testing or manual reset).
      #
      # @return [void]
      def reset!
        @mutex.synchronize do
          @calls_today = 0
          @warned = false
        end
      end

      private

      def warn_if_approaching_limit
        return if @warned
        return unless @calls_today >= (@daily_budget * WARN_THRESHOLD).to_i

        @warned = true
        @warn_io&.puts(
          "WARNING: Unblocked API usage at #{@calls_today}/#{@daily_budget} for this run " \
          "(#{remaining} calls remaining in the per-run cap)"
        )
      end
    end
  end
end
