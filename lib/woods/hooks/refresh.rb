# frozen_string_literal: true

require 'base64'
require 'json'
require 'woods/input_rules'
require 'woods/source_inputs/handoff'
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
        actions, paths = extraction_work(output)
        return report_dropped_ruby(output) if paths.empty?

        extractor = Extractor.new(output_dir: output)
        RakeHelpers.woods_with_extraction_lock(output) do
          actions.include?(:full) ? extractor.extract_all : extractor.extract_changed(paths)
          extractor.raise_on_publication_failure!
        end
      end

      private

      # Declared source roots come from the launcher's handoff when this is
      # its child, and from the published manifest otherwise (F15).
      def input_rules(output)
        @input_rules ||= begin
          roots = SourceInputs::Handoff.extra_roots | InputRules.for_index(output).extra_roots
          InputRules.new(extra_roots: roots)
        end
      end

      # Silence stays the contract for genuinely irrelevant input; a Ruby file
      # the rules dropped is the one case worth one line, since a root nobody
      # declared looks exactly like a change nobody made.
      def report_dropped_ruby(output)
        paths = @batch.fetch('events').map { |event| event.fetch('path') }
        dropped = paths.select { |path| path.end_with?('.rb') }.uniq
        return if dropped.empty?

        warn "Woods hook: dropped #{dropped.size} Ruby path(s) not under a known source root: " \
             "#{dropped.first(5).join(', ')} (known roots: #{input_rules(output).known_roots_summary}; " \
             'declare one with woods-extract --source-root PATH)'
      end

      def extraction_work(output)
        rules = input_rules(output)
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
