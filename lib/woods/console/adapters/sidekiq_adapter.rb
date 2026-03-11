# frozen_string_literal: true

require_relative 'job_adapter'

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
      class SidekiqAdapter < JobAdapter
        # Check if Sidekiq is available in the current environment.
        #
        # @return [Boolean]
        def self.available?
          !!defined?(::Sidekiq)
        end

        private

        def prefix
          'sidekiq'
        end
      end
    end
  end
end
