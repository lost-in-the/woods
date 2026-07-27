# frozen_string_literal: true

require 'json'
require 'fileutils'
require 'time'
require 'socket'

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

      # A status record older than this is not believed, however healthy it
      # claims to be. Generous relative to a debounce window, because an idle
      # daemon only rewrites its status when something happens.
      STALE_AFTER = 900 # 15 minutes

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
          'host' => self.class.host_identity,
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

      # Is a daemon currently maintaining this index?
      #
      # Three things have to hold, and each rules out a different way the
      # status file lies: the state has to be one a live daemon writes, the
      # recorded pid has to still exist (a `kill -9` leaves the file behind),
      # and the record has to be recent (a machine that lost power leaves a
      # `running` record with a pid some unrelated process now owns).
      #
      # Callers use this to decide whether to do the work themselves — a
      # session-start hook that would otherwise run `woods:incremental` can
      # skip it when a daemon is already on the job.
      #
      # @param max_age [Numeric] seconds after which a record is disbelieved
      # @return [Boolean]
      def alive?(max_age: STALE_AFTER)
        record = read
        return false unless %w[running degraded].include?(record['state'])
        return false unless same_host?(record['host'])
        return false unless process_alive?(record['pid'])

        recent?(record['updated_at'], max_age)
      end

      # The identity a pid is only meaningful within.
      #
      # In a container the hostname defaults to the container id, so this
      # changes exactly when the pid namespace does.
      #
      # @return [String]
      def self.host_identity
        @host_identity ||= Socket.gethostname
      rescue StandardError
        'unknown'
      end

      # Remove the status file. Used on a clean shutdown by callers that would
      # rather leave no record than a stale "running" one.
      #
      # @return [void]
      def clear
        FileUtils.rm_f(@path)
      end

      private

      # A pid is only meaningful inside the namespace that issued it.
      #
      # The daemon runs in a dev container while the status file is read by
      # host-side worktree hooks through a bind mount — the documented
      # deployment. A container pid like 47 almost always exists on the host, so
      # a host hook would read `running` plus a live-looking pid plus a fresh
      # timestamp and stand down while nothing was covering it. Comparing the
      # recorded host means a cross-namespace reader disbelieves the record
      # rather than misreading it.
      #
      # Records written before this field existed have no host; treat them as
      # same-host so an in-place upgrade does not declare a live daemon dead.
      def same_host?(host)
        host.nil? || host == self.class.host_identity
      end

      # Signal 0 asks "could I signal this process?" without sending anything.
      # EPERM means it exists but belongs to someone else — still alive.
      def process_alive?(pid)
        return false unless pid.is_a?(Integer) && pid.positive?

        Process.kill(0, pid)
        true
      rescue Errno::ESRCH
        false
      rescue Errno::EPERM
        true
      end

      def recent?(iso8601, max_age)
        return false if iso8601.nil?

        Time.now - Time.parse(iso8601) <= max_age
      rescue ArgumentError, TypeError
        false
      end
    end
  end
end
