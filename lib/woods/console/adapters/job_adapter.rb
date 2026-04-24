# frozen_string_literal: true

module Woods
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
        # A nil id is dropped from the bridge request so downstream tools see
        # a missing parameter rather than an explicit `nil` — symmetric with
        # `CacheAdapter.stats(namespace: nil)`.
        #
        # @param id [Object, nil] Job ID
        # @return [Hash] Bridge request
        def find_job(id:)
          { tool: "#{prefix}_find_job", params: { id: id }.compact }
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
        # A nil id is dropped from the bridge request — see #find_job.
        #
        # @param id [Object, nil] Job ID
        # @return [Hash] Bridge request
        def retry_job(id:)
          { tool: "#{prefix}_retry_job", params: { id: id }.compact }
        end

        private

        def prefix
          raise NotImplementedError, "#{self.class}#prefix must be implemented"
        end
      end
    end
  end
end
