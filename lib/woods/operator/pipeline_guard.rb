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
      # Fails closed on state this process cannot trust: :missing is the
      # legitimate "never run" case and allows, but :corrupt and
      # :permission_denied used to be indistinguishable from :missing —
      # both parsed to `{}` (or crashed uncaught) and let the operation
      # through, silently defeating the cooldown on exactly the state that
      # means it can no longer be verified.
      #
      # @param operation [Symbol, String] Operation name
      # @return [Boolean]
      def allow?(operation)
        case state_status
        when :corrupt, :permission_denied
          false
        else
          last = last_run(operation)
          return true if last.nil?

          (Time.now - last) >= @cooldown
        end
      end

      # Diagnose the on-disk cooldown state without side effects, distinguishing
      # the three states {#allow?} used to collapse into one silent outcome —
      # public callers (the MCP pipeline tools) need to tell a fresh install
      # apart from a state file that needs operator attention.
      #
      # @return [Symbol] `:ok`, `:missing`, `:corrupt`, or `:permission_denied`
      def state_status
        return :missing unless File.exist?(@state_path)

        parsed = JSON.parse(File.read(@state_path))
        parsed.is_a?(Hash) ? :ok : :corrupt
      rescue Errno::EACCES
        :permission_denied
      rescue JSON::ParserError
        :corrupt
      rescue Errno::ENOENT
        :missing
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
        return false unless requested_state_present?(operations)

        with_existing_locked_state do |state|
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
        state = content.empty? ? {} : JSON.parse(content)
        state.is_a?(Hash) ? state : {}
      rescue JSON::ParserError
        {}
      end

      def requested_state_present?(operations)
        File.open(@state_path, File::RDONLY) do |file|
          file.flock(File::LOCK_SH)
          state = parse_state(file.read)
          operations.any? { |key| state.key?(key) }
        end
      rescue Errno::ENOENT
        false
      end

      def with_existing_locked_state
        File.open(@state_path, File::RDWR) do |file|
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
      rescue Errno::ENOENT
        false
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

        parse_state(File.read(@state_path))
      rescue Errno::ENOENT, Errno::EACCES
        {}
      end
    end
  end
end
