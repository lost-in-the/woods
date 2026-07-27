# frozen_string_literal: true

require 'json'

require_relative '../atomic_file'

module Woods
  module Watch
    # The daemon's own liveness and health, written where a reader can find it.
    #
    # A stale index is only dangerous when nothing says so. An agent asking
    # `woods_status` needs to distinguish three situations that look identical
    # from the index alone:
    #
    # * **running** — the index is current, or will be within a debounce window.
    # * **degraded** — the daemon is alive but *cannot* update: a syntax error
    #   mid-edit made the reload fail, the watcher died, extraction raised. The
    #   index is intact and frozen at a known generation; the reason says why.
    # * **stopped** — nothing is maintaining this index. Fall back to whatever
    #   the last explicit run left.
    #
    # Degraded is the important one. #164's failure posture is that a daemon
    # never crash-loops and never publishes a partial write, which means it
    # spends real time in a state where the answer it can give is out of date.
    # Saying so is the difference between a stale answer and a wrong one.
    class Status
      FILENAME = 'watch_status.json'

      STATES = %i[running degraded stopped].freeze

      # @param output_dir [String, Pathname] index directory
      # @param clock [#call] returns the ISO8601 stamp for a write
      def initialize(output_dir:, clock: -> { Time.now.utc.iso8601 })
        @path = File.join(output_dir.to_s, FILENAME)
        @clock = clock
      end

      # @return [String] absolute path to the status file
      attr_reader :path

      # Record the daemon's current state.
      #
      # @param state [Symbol] one of {STATES}
      # @param generation [Integer, nil] the generation the index is at
      # @param reason [String, nil] required in spirit for `:degraded`
      # @param details [Hash] extra fields (pid, last batch size, timings)
      # @return [Hash] the record as written
      def write(state:, generation: nil, reason: nil, **details)
        raise ArgumentError, "Unknown watch state #{state.inspect}" unless STATES.include?(state)

        record = {
          'state' => state.to_s,
          'reason' => reason,
          'generation' => generation,
          'pid' => Process.pid,
          'updated_at' => @clock.call
        }.merge(details.transform_keys(&:to_s))

        AtomicFile.write(@path, JSON.generate(record))
        record
      end

      # The last recorded state, or a stopped record when there is none.
      #
      # @return [Hash] string-keyed status record
      def read
        return { 'state' => 'stopped', 'reason' => 'no daemon has run' } unless File.exist?(@path)

        JSON.parse(File.read(@path))
      rescue JSON::ParserError, SystemCallError => e
        { 'state' => 'stopped', 'reason' => "unreadable status file: #{e.message}" }
      end

      # Remove the status file. Used on a clean shutdown by callers that would
      # rather leave no record than a stale "running" one.
      #
      # @return [void]
      def clear
        FileUtils.rm_f(@path)
      end
    end
  end
end
