# frozen_string_literal: true

require 'digest'
require 'woods/input_rules'

module Woods
  module Hooks
    # Claude context events are deliberately separate from refresh queue records.
    class ContextEvent
      MAX_FILE_BYTES = 1_048_576
      attr_reader :root, :path, :kind, :session

      def initialize(input, root: nil)
        validate_root!(input)

        @logical_root = File.expand_path(input['cwd'])
        @root = File.realpath(root || @logical_root)
        @kind = input['hook_event_name']
        @session = input['session_id'] if valid_string?(input['session_id'], 256)
        return if kind == 'SessionStart'

        raise ArgumentError unless kind == 'PostToolUse' && %w[Edit Write MultiEdit].include?(input['tool_name'])

        @path = relative_path(input.fetch('tool_input').fetch('file_path'))
      end

      def eligible?
        return true if kind == 'SessionStart'

        require 'woods/extractor' unless defined?(Woods::Extractor::EXTRACTORS)
        InputRules.new.action(path) != :ignore
      end

      def fingerprint
        return 'orientation' if kind == 'SessionStart'

        flags = File::RDONLY | File::NONBLOCK
        flags |= File::NOFOLLOW if defined?(File::NOFOLLOW)
        File.open(File.join(root, path), flags) do |file|
          return nil unless file.stat.file? && file.stat.size <= MAX_FILE_BYTES

          bytes = file.read(MAX_FILE_BYTES + 1)
          return nil if bytes.bytesize > MAX_FILE_BYTES

          Digest::SHA256.hexdigest(bytes)
        end
      rescue Errno::ENOENT
        'missing'
      rescue SystemCallError, IOError
        nil
      end

      private

      def validate_root!(input)
        raise ArgumentError unless input.is_a?(Hash) && valid_string?(input['cwd']) && input['cwd'].start_with?('/')
      end

      def valid_string?(value, limit = 4096)
        value.is_a?(String) && !value.empty? && value.bytesize <= limit &&
          value.valid_encoding? && !value.include?("\0")
      end

      def relative_path(value)
        raise ArgumentError unless valid_string?(value)

        prefix = [@logical_root, root].find { |base| value.start_with?("#{base}/") }
        relative = prefix ? value.delete_prefix("#{prefix}/") : value
        validate_parts!(relative)
        validate_containment!(relative)
        relative
      end

      def validate_parts!(relative)
        parts = relative.split('/', -1)
        raise ArgumentError if relative.start_with?('/') || parts.size > 64
        raise ArgumentError if parts.any? { |part| ['', '.', '..'].include?(part) }
      end

      def validate_containment!(relative)
        candidate = File.join(root, relative)
        candidate = File.dirname(candidate) until File.exist?(candidate) || File.symlink?(candidate)
        resolved = File.realpath(candidate)
        raise ArgumentError unless resolved == root || resolved.start_with?("#{root}/")
      end
    end
  end
end
