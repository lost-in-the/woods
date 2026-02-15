# frozen_string_literal: true

module CodebaseIndex
  module Console
    module Adapters
      # Job backend adapter for Solid Queue.
      #
      # Builds bridge requests for Solid Queue job stats, failure listing,
      # job lookup, scheduled jobs, and retry operations.
      #
      # @example
      #   adapter = SolidQueueAdapter.new
      #   adapter.queue_stats  # => { tool: 'solid_queue_queue_stats', params: {} }
      #
      class SolidQueueAdapter
        # Check if Solid Queue is available in the current environment.
        #
        # @return [Boolean]
        def self.available?
          defined?(::SolidQueue) ? true : false
        end

        # Get queue statistics (sizes, latencies).
        #
        # @return [Hash] Bridge request
        def queue_stats
          { tool: 'solid_queue_queue_stats', params: {} }
        end

        # List recent job failures.
        #
        # @param limit [Integer] Max failures (default: 10, max: 100)
        # @return [Hash] Bridge request
        def recent_failures(limit: 10)
          limit = [limit, 100].min
          { tool: 'solid_queue_recent_failures', params: { limit: limit } }
        end

        # Find a job by its ID.
        #
        # @param id [Object] Solid Queue job ID
        # @return [Hash] Bridge request
        def find_job(id:)
          { tool: 'solid_queue_find_job', params: { id: id } }
        end

        # List scheduled jobs.
        #
        # @param limit [Integer] Max jobs (default: 20, max: 100)
        # @return [Hash] Bridge request
        def scheduled_jobs(limit: 20)
          limit = [limit, 100].min
          { tool: 'solid_queue_scheduled_jobs', params: { limit: limit } }
        end

        # Retry a failed job.
        #
        # @param id [Object] Solid Queue job ID
        # @return [Hash] Bridge request
        def retry_job(id:)
          { tool: 'solid_queue_retry_job', params: { id: id } }
        end
      end
    end
  end
end
