# frozen_string_literal: true

require 'json'
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
    # Two more states exist only on the read side, because a daemon cannot
    # amend its own record after it dies (see {#report}):
    #
    # * **stale** — the record claims `running` or `degraded` but is older than
    #   {STALE_AFTER}; whatever wrote it has stopped heartbeating.
    # * **dead** — the record names a same-host pid that no longer exists, or
    #   (on Linux) one that has exited and is waiting to be reaped.
    # * **unverified** — a fresh record from another host that this reader is
    #   not opted in to trust (see {#alive?}); the daemon may well be alive in
    #   its container, but nothing here can say so.
    #
    # The daemon never writes any of these; {#write} rejects them. The recorded state
    # travels alongside as `recorded_state` so no reader loses information.
    #
    # Degraded is the important one. #164's failure posture is that a daemon
    # never crash-loops and never publishes a partial write, which means it
    # spends real time in a state where the answer it can give is out of date.
    # Saying so is the difference between a stale answer and a wrong one.
    class Status
      FILENAME = 'watch_status.json'

      STATES = %i[running degraded stopped].freeze

      # States only a reader derives; see {#report}.
      DERIVED_STATES = %i[stale dead unverified].freeze

      # A status record older than this is not believed, however healthy it
      # claims to be. The daemon heartbeats every five minutes, including
      # while idle, so this allows two missed heartbeats.
      STALE_AFTER = 900 # 15 minutes
      MAX_FUTURE_SKEW = 30 # seconds of clock difference tolerated across hosts

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

        # 0644 on purpose (O1): host-side worktree hooks read this file
        # through a bind mount (the documented deployment, see Daemon's
        # daemon-deference check), making it the one artifact with a
        # cross-boundary consumer. Everything else Woods writes keeps
        # AtomicFile's restrictive 0600 default.
        AtomicFile.write(@path, JSON.generate(record), mode: 0o644)
        record
      end

      # The last recorded state, or a stopped record when there is none.
      #
      # @return [Hash] string-keyed status record
      def read
        return { 'state' => 'stopped', 'reason' => 'no daemon has run' } unless File.exist?(@path)

        JSON.parse(AtomicFile.read(@path))
      rescue JSON::ParserError, SystemCallError, EncodingError => e
        { 'state' => 'stopped', 'reason' => "unreadable status file: #{e.message}" }
      end

      # Is a daemon currently maintaining this index?
      #
      # Require a live state, a positive pid, and a recent timestamp. A local
      # pid must still exist; foreign-host trust explicitly substitutes bounded
      # heartbeat freshness for that uncheckable process evidence. A crashed
      # foreign daemon can therefore remain believable until the record ages out.
      #
      # Callers use this to decide whether to do the work themselves — a
      # session-start hook that would otherwise run `woods:incremental` can
      # skip it when a daemon is already on the job.
      #
      # @param max_age [Numeric] seconds after which a record is disbelieved
      # @param trust_foreign_host [Boolean] trust a fresh foreign-host record
      #   without a local pid check; defaults to WOODS_WATCH_TRUST_FOREIGN_HOST=1
      # @return [Boolean]
      def alive?(max_age: STALE_AFTER, trust_foreign_host: ENV['WOODS_WATCH_TRUST_FOREIGN_HOST'] == '1')
        record = read
        return false unless %w[running degraded].include?(record['state'])
        return false unless record['pid'].is_a?(Integer) && record['pid'].positive?
        return false unless recent?(record['updated_at'], max_age)
        return trust_foreign_host unless same_host?(record['host'])

        process_alive?(record['pid'])
      end

      # The record as a reader should believe it.
      #
      # `state` is whatever the daemon last wrote, and a daemon killed with
      # `kill -9` leaves `running` behind forever. {#alive?} already knows
      # better, but a consumer that reads `state` and ignores `alive` concludes
      # the index is being kept fresh. Here the two agree: `state` becomes
      # `stale` when the record has aged past +max_age+, `dead` when it names a
      # same-host pid that no longer exists, and stays as recorded only while
      # the daemon is alive. The daemon's own word is kept as `recorded_state`.
      #
      # A fresh foreign-host record that this reader is not opted in to trust
      # is neither provably dead nor stale, but reporting it as `running` beside
      # `alive: false` is the contradiction this exists to remove: it becomes
      # `unverified`. `dead` and `stale` are only ever claimed on evidence.
      #
      # @param max_age [Numeric] see {#alive?}
      # @param trust_foreign_host [Boolean] see {#alive?}
      # @return [Hash] string-keyed record with `state`, `recorded_state`, `alive`
      def report(max_age: STALE_AFTER, trust_foreign_host: ENV['WOODS_WATCH_TRUST_FOREIGN_HOST'] == '1')
        record = read
        alive = alive?(max_age: max_age, trust_foreign_host: trust_foreign_host)
        record.merge(
          'state' => derived_state(record, alive: alive, max_age: max_age),
          'recorded_state' => record['state'],
          'alive' => alive
        )
      end

      # The identity a pid is only meaningful within.
      #
      # In a container the hostname defaults to the container id, so this
      # usually changes with the pid namespace. Custom or reused hostnames
      # cannot establish namespace identity.
      #
      # @return [String]
      def self.host_identity
        @host_identity ||= Socket.gethostname
      rescue StandardError
        'unknown'
      end

      # Does a same-host pid name a process that is still running?
      #
      # Signal 0 asks "could I signal this process?" without sending anything;
      # EPERM means it exists but belongs to someone else, so it counts as
      # alive. Signal 0 also succeeds for a zombie, a process that has exited
      # but whose parent has not reaped it. A watcher re-parented to a PID 1
      # that never reaps (a container without an init) stays one after it is
      # killed, so on Linux a pid whose `/proc/<pid>/status` reports `State: Z`
      # is dead. Elsewhere, and when that file cannot be read, signal 0 decides.
      #
      # @param pid [Integer]
      # @return [Boolean]
      def self.pid_alive?(pid)
        return false unless pid.is_a?(Integer) && pid.positive?

        Process.kill(0, pid)
        !zombie?(pid)
      rescue Errno::ESRCH
        false
      rescue Errno::EPERM
        !zombie?(pid)
      end

      # @param pid [Integer]
      # @return [Boolean] true only when Linux /proc reports the pid as a zombie
      #   (read as bytes: the `Name:` line holds the process name, which need
      #   not be ASCII or valid UTF-8)
      def self.zombie?(pid)
        return false unless RUBY_PLATFORM.include?('linux')

        File.binread("/proc/#{pid}/status")[/^State:\s*(\S)/n, 1] == 'Z'
      rescue SystemCallError, IOError
        false
      end
      private_class_method :zombie?

      private

      # `dead` outranks `stale`: a vanished pid is direct evidence, an old
      # timestamp only circumstantial. A record the daemon itself marked
      # `stopped` is left alone — there is nothing to derive. Whatever claims
      # `running` or `degraded` while `alive?` says no is never reported as such.
      def derived_state(record, alive:, max_age:)
        recorded = record['state']
        return recorded if alive || !%w[running degraded].include?(recorded)
        return 'dead' if known_dead?(record)
        return 'stale' unless recent?(record['updated_at'], max_age)

        'unverified'
      end

      # Only a same-host pid can be checked; a foreign one is never declared dead.
      def known_dead?(record)
        pid = record['pid']
        same_host?(record['host']) && pid.is_a?(Integer) && pid.positive? && !process_alive?(pid)
      end

      # A pid is only meaningful inside the namespace that issued it.
      #
      # The daemon runs in a dev container while the status file is read by
      # host-side worktree hooks through a bind mount — the documented
      # deployment. A container pid like 47 almost always exists on the host, so
      # a host hook would read `running` plus a live-looking pid plus a fresh
      # timestamp and stand down while nothing was covering it. Comparing the
      # recorded host keeps a cross-namespace reader from checking an unrelated
      # local pid. Foreign records are rejected unless freshness trust is enabled.
      #
      # Records written before this field existed have no host; treat them as
      # same-host so an in-place upgrade does not declare a live daemon dead.
      def same_host?(host)
        host.nil? || host == self.class.host_identity
      end

      # See {.pid_alive?}.
      def process_alive?(pid)
        self.class.pid_alive?(pid)
      end

      # Both sides of this comparison must come from the same clock.
      #
      # `@clock` is injected so a spec can drive staleness without sleeping for
      # a quarter of an hour; reading the left-hand side from `Time.now`
      # regardless made that injection a no-op for the one thing it exists to
      # test — a stubbed clock could write an `updated_at` far in the past or
      # future and `recent?` would still answer from the wall clock.
      def recent?(iso8601, max_age)
        return false if iso8601.nil?

        age = Time.iso8601(@clock.call) - Time.iso8601(iso8601)
        age.between?(-MAX_FUTURE_SKEW, max_age)
      rescue ArgumentError, TypeError
        false
      end
    end
  end
end
