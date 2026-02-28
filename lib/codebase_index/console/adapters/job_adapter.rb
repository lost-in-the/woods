# frozen_string_literal: true

module CodebaseIndex
  module Console
    module Adapters
      # Base class for job backend adapters.
      #
      # Subclasses implement `self.available?` and a private `prefix` method.
      # The prefix is used to build bridge tool names (e.g., "sidekiq_queue_stats").
      #
      # @example
      #   class MyAdapter < JobAdapter
      #     def self.available? = !!defined?(::MyQueue)
      #     private
      #     def prefix = 'my_queue'
      #   end
      #
      class JobAdapter
        # Get queue statistics (sizes, latencies).
        #
        # @return [Hash] Bridge request
        def queue_stats
          { tool: "#{prefix}_queue_stats", params: {} }
        end

        # List recent job failures.
        #
        # @param limit [Integer] Max failures (default: 10, max: 100)
        # @return [Hash] Bridge request
        def recent_failures(limit: 10)
          limit = [limit, 100].min
          { tool: "#{prefix}_recent_failures", params: { limit: limit } }
        end

        # Find a job by its ID.
        #
        # @param id [Object] Job ID
        # @return [Hash] Bridge request
        def find_job(id:)
          { tool: "#{prefix}_find_job", params: { id: id } }
        end

        # List scheduled jobs.
        #
        # @param limit [Integer] Max jobs (default: 20, max: 100)
        # @return [Hash] Bridge request
        def scheduled_jobs(limit: 20)
          limit = [limit, 100].min
          { tool: "#{prefix}_scheduled_jobs", params: { limit: limit } }
        end

        # Retry a failed job.
        #
        # @param id [Object] Job ID
        # @return [Hash] Bridge request
        def retry_job(id:)
          { tool: "#{prefix}_retry_job", params: { id: id } }
        end

        private

        def prefix
          raise NotImplementedError, "#{self.class}#prefix must be implemented"
        end
      end
    end
  end
end
