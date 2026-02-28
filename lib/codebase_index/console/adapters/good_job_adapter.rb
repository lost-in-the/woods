# frozen_string_literal: true

require_relative 'job_adapter'

module CodebaseIndex
  module Console
    module Adapters
      # Job backend adapter for GoodJob.
      #
      # Builds bridge requests for GoodJob queue stats, failure listing,
      # job lookup, scheduled jobs, and retry operations.
      #
      # @example
      #   adapter = GoodJobAdapter.new
      #   adapter.queue_stats  # => { tool: 'good_job_queue_stats', params: {} }
      #
      class GoodJobAdapter < JobAdapter
        # Check if GoodJob is available in the current environment.
        #
        # @return [Boolean]
        def self.available?
          !!defined?(::GoodJob)
        end

        private

        def prefix
          'good_job'
        end
      end
    end
  end
end
