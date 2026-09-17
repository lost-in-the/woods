# frozen_string_literal: true

require 'base64'
require 'json'
require 'woods/input_rules'
require 'woods/rake_helpers'

module Woods
  module Hooks
    # The JSON argument is portable across host/container command boundaries.
    # Exit 75 explicitly defers work; only successful consumption acknowledges it.
    class Refresh
      MAX_BYTES = 128 * 1024
      MAX_EVENTS = 1000
      OPERATIONS = %w[add update delete move].freeze

      def initialize(encoded)
        raise ArgumentError, 'hook batch too large' if encoded.to_s.bytesize > MAX_BYTES * 2

        @batch = JSON.parse(Base64.strict_decode64(encoded.to_s))
        validate!
      end

      def call
        output = File.expand_path(@batch.fetch('output'), RakeHelpers.woods_task_root)
        if RakeHelpers.woods_daemon_coverage(output) == :running
          warn 'Woods hook deferred: watch daemon is active; this batch has not been acknowledged.'
          exit 75
        end

        Rake::Task[:environment].invoke
        require 'woods/extractor'
        actions, paths = extraction_work
        return if paths.empty?

        extractor = Extractor.new(output_dir: output)
        RakeHelpers.woods_with_extraction_lock(output) do
          actions.include?(:full) ? extractor.extract_all : extractor.extract_changed(paths)
          extractor.raise_on_publication_failure!
        end
      end

      private

      def extraction_work
        rules = InputRules.new
        events = @batch.fetch('events')
        actions = events.map { |event| rules.action(event.fetch('path'), operation: event.fetch('operation')) }
        paths = events.zip(actions).filter_map { |event, action| event.fetch('path') unless action == :ignore }.uniq
        [actions, paths]
      end

      def validate!
        raise ArgumentError, 'unsupported hook batch' unless @batch.is_a?(Hash) && @batch['version'] == 1
        raise ArgumentError, 'invalid hook output' unless valid_string?(@batch['output'])

        events = @batch['events']
        raise ArgumentError, 'invalid hook events' unless valid_events?(events)
      end

      def valid_events?(events)
        events.is_a?(Array) && events.size.between?(1, MAX_EVENTS) && events.all? { |event| valid_event?(event) }
      end

      def valid_event?(event)
        return false unless event.is_a?(Hash) && OPERATIONS.include?(event['operation'])

        path = event['path']
        valid_string?(path) && !path.start_with?('/') && path.split('/', -1).none? do |part|
          ['', '.', '..'].include?(part)
        end
      end

      def valid_string?(value)
        value.is_a?(String) && !value.empty? && !value.include?("\0") && value.bytesize <= MAX_BYTES
      end
    end
  end
end
