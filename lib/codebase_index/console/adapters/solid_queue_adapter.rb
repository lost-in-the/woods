# frozen_string_literal: true

require_relative 'job_adapter'

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
      class SolidQueueAdapter < JobAdapter
        # Check if Solid Queue is available in the current environment.
        #
        # @return [Boolean]
        def self.available?
          !!defined?(::SolidQueue)
        end

        private

        def prefix
          'solid_queue'
        end
      end
    end
  end
end
