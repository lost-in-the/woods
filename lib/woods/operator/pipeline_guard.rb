# frozen_string_literal: true

require 'json'
require 'fileutils'
require 'time'

module Woods
  module Operator
    # Rate limiter for pipeline operations using file-based state.
    #
    # Enforces a cooldown between consecutive runs of the same operation
    # to prevent accidental repeated extraction or embedding.
    #
    # @example
    #   guard = PipelineGuard.new(state_dir: '/tmp', cooldown: 300)
    #   if guard.allow?(:extraction)
    #     run_extraction
    #     guard.record!(:extraction)
    #   end
    #
    class PipelineGuard
      SUPPORTED_OPERATIONS = %w[extraction embedding].freeze

      # @param state_dir [String] Directory for persisting state
      # @param cooldown [Integer] Minimum seconds between runs
      def initialize(state_dir:, cooldown: 300)
        @state_dir = state_dir
        @cooldown = cooldown
        @state_path = File.join(state_dir, 'pipeline_guard.json')
      end

      # Check if an operation is allowed (cooldown elapsed).
      #
      # @param operation [Symbol, String] Operation name
      # @return [Boolean]
      def allow?(operation)
        last = last_run(operation)
        return true if last.nil?

        (Time.now - last) >= @cooldown
      end

      # Record that an operation has just run.
      #
      # @param operation [Symbol, String] Operation name
      # @return [void]
      def record!(operation)
        with_locked_state do |state|
          state[operation.to_s] = Time.now.iso8601
          true
        end
        nil
      end

      # Reset one supported operation or all supported operations atomically.
      #
      # @param operation [Symbol, String] `:extraction`, `:embedding`, or `:all`
      # @return [Boolean] true when at least one cooldown was removed
      # @raise [ArgumentError] when the operation is unsupported
      def reset!(operation)
        operations = reset_operations(operation)
        with_locked_state do |state|
          changed = false
          operations.each do |key|
            next unless state.key?(key)

            state.delete(key)
            changed = true
          end
          changed
        end
      end

      # Get the last run time for an operation.
      #
      # @param operation [Symbol, String] Operation name
      # @return [Time, nil]
      def last_run(operation)
        state = read_state
        timestamp = state[operation.to_s]
        return nil if timestamp.nil?

        Time.parse(timestamp)
      rescue ArgumentError
        nil
      end

      private

      def with_locked_state
        FileUtils.mkdir_p(@state_dir)
        File.open(@state_path, File::RDWR | File::CREAT) do |file|
          file.flock(File::LOCK_EX)
          state = parse_state(file.read)
          changed = yield(state)
          if changed
            file.rewind
            file.write(JSON.generate(state))
            file.truncate(file.pos)
          end
          changed
        end
      end

      def parse_state(content)
        content.empty? ? {} : JSON.parse(content)
      rescue JSON::ParserError
        {}
      end

      def reset_operations(operation)
        key = operation.to_s
        return SUPPORTED_OPERATIONS if key == 'all'
        return [key] if SUPPORTED_OPERATIONS.include?(key)

        raise ArgumentError, "Unsupported pipeline operation: #{operation}"
      end

      # @return [Hash]
      def read_state
        return {} unless File.exist?(@state_path)

        JSON.parse(File.read(@state_path))
      rescue JSON::ParserError
        {}
      end
    end
  end
end
