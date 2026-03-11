# frozen_string_literal: true

module CodebaseIndex
  module Console
    module Tools
      # Tier 3: Analytics tools for monitoring live Rails application state.
      #
      # Provides request performance metrics, job queue monitoring,
      # cache statistics, and ActionCable channel status. Job-related
      # tools delegate to backend-specific adapters (Sidekiq, Solid Queue, GoodJob).
      #
      # Each method builds a bridge request hash from validated parameters.
      # The bridge executes the query against the Rails environment.
      #
      module Tier3
        module_function

        # List slowest endpoints by response time.
        #
        # @param limit [Integer] Max endpoints to return (default: 10, max: 100)
        # @param period [String] Time period (default: "1h")
        # @return [Hash] Bridge request
        def console_slow_endpoints(limit: 10, period: '1h')
          limit = [limit, 100].min
          { tool: 'slow_endpoints', params: { limit: limit, period: period } }
        end

        # Get error rates by controller or overall.
        #
        # @param period [String] Time period (default: "1h")
        # @param controller [String, nil] Filter by controller name
        # @return [Hash] Bridge request
        def console_error_rates(period: '1h', controller: nil)
          { tool: 'error_rates', params: { period: period, controller: controller }.compact }
        end

        # Get request throughput over time.
        #
        # @param period [String] Time period (default: "1h")
        # @param interval [String] Aggregation interval (default: "5m")
        # @return [Hash] Bridge request
        def console_throughput(period: '1h', interval: '5m')
          { tool: 'throughput', params: { period: period, interval: interval } }
        end

        # Get job queue statistics.
        #
        # @param queue [String, nil] Filter by queue name
        # @return [Hash] Bridge request
        def console_job_queues(queue: nil)
          { tool: 'job_queues', params: { queue: queue }.compact }
        end

        # List recent job failures.
        #
        # @param limit [Integer] Max failures to return (default: 10, max: 100)
        # @param queue [String, nil] Filter by queue name
        # @return [Hash] Bridge request
        def console_job_failures(limit: 10, queue: nil)
          limit = [limit, 100].min
          { tool: 'job_failures', params: { limit: limit, queue: queue }.compact }
        end

        # Find a job by ID, optionally retry it (requires confirmation).
        #
        # @param job_id [String] Job identifier
        # @param retry_job [Boolean, nil] Whether to retry the job
        # @return [Hash] Bridge request, with requires_confirmation if retry requested
        def console_job_find(job_id:, retry_job: nil)
          result = { tool: 'job_find', params: { job_id: job_id, retry: retry_job }.compact }
          result[:requires_confirmation] = true if retry_job
          result
        end

        # List scheduled/upcoming jobs.
        #
        # @param limit [Integer] Max jobs to return (default: 20, max: 100)
        # @return [Hash] Bridge request
        def console_job_schedule(limit: 20)
          limit = [limit, 100].min
          { tool: 'job_schedule', params: { limit: limit } }
        end

        # Get Redis server information.
        #
        # @param section [String, nil] Redis INFO section filter (e.g., "memory", "stats")
        # @return [Hash] Bridge request
        def console_redis_info(section: nil)
          { tool: 'redis_info', params: { section: section }.compact }
        end

        # Get cache store statistics.
        #
        # @param namespace [String, nil] Cache namespace filter
        # @return [Hash] Bridge request
        def console_cache_stats(namespace: nil)
          { tool: 'cache_stats', params: { namespace: namespace }.compact }
        end

        # Get ActionCable channel status.
        #
        # @param channel [String, nil] Filter by channel name
        # @return [Hash] Bridge request
        def console_channel_status(channel: nil)
          { tool: 'channel_status', params: { channel: channel }.compact }
        end
      end
    end
  end
end
