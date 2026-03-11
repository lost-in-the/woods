# frozen_string_literal: true

require 'json'
require 'fileutils'
require 'time'

module CodebaseIndex
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
        FileUtils.mkdir_p(@state_dir)
        File.open(@state_path, File::RDWR | File::CREAT) do |f|
          f.flock(File::LOCK_EX)
          content = f.read
          state = if content.empty?
                    {}
                  else
                    begin
                      JSON.parse(content)
                    rescue StandardError
                      {}
                    end
                  end
          state[operation.to_s] = Time.now.iso8601
          f.rewind
          f.write(JSON.generate(state))
          f.truncate(f.pos)
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
