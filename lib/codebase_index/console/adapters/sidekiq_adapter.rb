# frozen_string_literal: true

module CodebaseIndex
  module Console
    module Adapters
      # Job backend adapter for Sidekiq.
      #
      # Builds bridge requests for Sidekiq queue stats, failure listing,
      # job lookup, scheduled jobs, and retry operations.
      #
      # @example
      #   adapter = SidekiqAdapter.new
      #   adapter.queue_stats  # => { tool: 'sidekiq_queue_stats', params: {} }
      #
      class SidekiqAdapter
        # Check if Sidekiq is available in the current environment.
        #
        # @return [Boolean]
        def self.available?
          defined?(::Sidekiq) ? true : false
        end

        # Get queue statistics (sizes, latencies).
        #
        # @return [Hash] Bridge request
        def queue_stats
          { tool: 'sidekiq_queue_stats', params: {} }
        end

        # List recent job failures.
        #
        # @param limit [Integer] Max failures (default: 10, max: 100)
        # @return [Hash] Bridge request
        def recent_failures(limit: 10)
          limit = [limit, 100].min
          { tool: 'sidekiq_recent_failures', params: { limit: limit } }
        end

        # Find a job by its ID.
        #
        # @param id [String] Sidekiq job ID
        # @return [Hash] Bridge request
        def find_job(id:)
          { tool: 'sidekiq_find_job', params: { id: id } }
        end

        # List scheduled jobs.
        #
        # @param limit [Integer] Max jobs (default: 20, max: 100)
        # @return [Hash] Bridge request
        def scheduled_jobs(limit: 20)
          limit = [limit, 100].min
          { tool: 'sidekiq_scheduled_jobs', params: { limit: limit } }
        end

        # Retry a failed job.
        #
        # @param id [String] Sidekiq job ID
        # @return [Hash] Bridge request
        def retry_job(id:)
          { tool: 'sidekiq_retry_job', params: { id: id } }
        end
      end
    end
  end
end
