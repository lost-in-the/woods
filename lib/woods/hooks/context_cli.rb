# frozen_string_literal: true

require 'json'
require 'timeout'

module Woods
  module Hooks
    # The plugin's independent process-group deadline also includes bundle/Ruby
    # startup. This inner deadline keeps ordinary direct calls short as well.
    class ContextCLI
      MAX_INPUT_BYTES = 1_048_576
      HELP = 'Usage: woods-hook-context SessionStart|PostToolUse < claude-event.json; ' \
             'opt in with WOODS_HOOK_CONTEXT_ENABLED=1. Prefer the bounded plugin hook entry point.'

      def self.run(kind, input: $stdin, output: $stdout)
        return output.puts(HELP) || 0 if kind == '--help'

        return 0 if ENV['WOODS_HOOKS_DISABLED'] == '1' || ENV['WOODS_HOOK_CONTEXT_ENABLED'] != '1'
        return 0 unless %w[SessionStart PostToolUse].include?(kind)

        Timeout.timeout(0.65) do
          require 'woods'
          require 'woods/hooks/context_hint'
          require 'woods/hooks/context_state'
          emit(kind, input, output)
        end
        0
      rescue Timeout::Error, JSON::ParserError, ArgumentError, KeyError, TypeError, SystemCallError, IOError
        # Missing/degraded/slow inputs are optional context, not permission to
        # run extraction, read application data, or acknowledge queued edits.
        0
      end

      def self.emit(kind, input, output)
        bytes = input.read(MAX_INPUT_BYTES + 1)
        return if bytes.bytesize > MAX_INPUT_BYTES

        event = JSON.parse(bytes)
        return unless event.is_a?(Hash) && event['hook_event_name'] == kind

        root = ENV['WOODS_HOOK_CONTEXT_ROOT'] || event.fetch('cwd')
        directory = File.expand_path(ENV.fetch('WOODS_OUTPUT', 'tmp/woods'), root)
        result = ContextHint.new(event: event, output_dir: directory, root: root).call
        return unless result

        ContextState.new(directory).emit(result) do
          output.write(ContextOutput.new(kind).encode(result.fetch(:context)))
          output.flush
        end
      end
      private_class_method :emit
    end
  end
end
