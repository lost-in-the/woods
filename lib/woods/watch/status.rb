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
    # Degraded is the important one. #164's failure posture is that a daemon
    # never crash-loops and never publishes a partial write, which means it
    # spends real time in a state where the answer it can give is out of date.
    # Saying so is the difference between a stale answer and a wrong one.
    class Status
      FILENAME = 'watch_status.json'

      STATES = %i[running degraded stopped].freeze

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

      private

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
