# frozen_string_literal: true

require_relative 'managed_process'
require_relative 'lifecycle'
require_relative 'supervision_status'
require_relative 'supervisor_reporting'
require_relative 'claim_lease'
require_relative 'status'
require_relative '../coordination/pipeline_lock'

module Woods
  module Watch
    # Foreground retry owner shared by Procfile and Puma installations.
    # It never retries configuration conflicts or silently takes over ownership.
    class Supervisor # rubocop:disable Metrics/ClassLength -- retry, park and shutdown share one foreground attempt state
      include SupervisorReporting

      RETRY_DELAYS = [1, 2, 4, 8, 16, 30].freeze
      PARKED_ADVICE = '[woods-watch] restart the owner after correcting configuration; no automatic takeover'
      # After its guardian has exited, the stopped watcher's group gets this long to vanish before its claim stays.
      GROUP_EXIT_WAIT = 1
      # Why a lock that names the stopped watcher stays. Either way a writer on
      # this host takes it over once its holder is gone, and any writer once it is stale.
      LOCK_REFUSALS = {
        alive: 'that watcher or a process in its group is still present',
        busy: 'another process held the lock guard'
      }.freeze

      # @param command [Array<String>] fresh application invocation on each attempt
      # @param root [String] application root
      # @param env [Hash] application environment
      # @param logger [#puts] diagnostic destination (stderr by default)
      # @param boot_timeout [Numeric] pre-identity boot deadline
      # @param shutdown_timeout [Numeric] graceful application shutdown
      # @param retry_delays [Array<Numeric>] bounded retry schedule
      # rubocop:disable-next Metrics/ParameterLists -- independently injectable process policy and diagnostics
      def initialize(command:, root:, env: ENV.to_h, logger: $stderr, boot_timeout: 300,
                     shutdown_timeout: 10, retry_delays: RETRY_DELAYS)
        raise ArgumentError, 'WOODS_WATCH_IDLE_TIMEOUT must be unset for managed watching' unless
          env['WOODS_WATCH_IDLE_TIMEOUT'].to_s.strip.empty?

        @command = command
        @root = File.realpath(root)
        @env = env
        @logger = logger
        @boot_timeout = boot_timeout
        @shutdown_timeout = shutdown_timeout
        @retry_delays = retry_delays
        @token = SecureRandom.hex(16)
        @attempts = @failures = 0
        @stopping = false
      end

      # @return [String, nil] honest lifecycle state
      attr_reader :state, :attempts

      # @return [Integer] zero after owner-requested shutdown
      def run
        until @stopping
          run_attempt
          break if @stopping

          reason = retry_reason
          reason ? retry_after(reason) : park(@protocol.terminal || 'incompatible_or_stopped_task')
        end
        0
      ensure
        @process&.stop
        publish('stopped', 'owner_stopped')
      end

      # Signal-safe request; process cleanup occurs on the run thread.
      # @return [void]
      def stop
        @stopping = true
      end

      private

      def run_attempt
        prepare_attempt
        @process.start
        monitor_attempt
      rescue ArgumentError => e
        @invalid = true
        @logger.puts("[woods-watch] incompatible lifecycle: #{e.message}")
      ensure
        @process&.stop
        retire_stopped_watcher
      end

      # A watcher killed after the shutdown timeout releases neither its
      # extraction lock nor its claim. Lock first: a successor that finds no
      # claim must not then wait out a dead writer's lock, which from another
      # host it can judge only by age. Each step rescues its own failure.
      def retire_stopped_watcher
        index = @protocol&.index
        pid = @protocol&.child_pid
        return unless index && pid

        await_group_exit(pid)
        retire_stopped_lock(index, pid)
        retire_stopped_claim(index, pid)
      end

      # Only a lock recorded on this host by this attempt's watcher pid, through the lock's own guarded path.
      def retire_stopped_lock(index, pid)
        lock = Coordination::PipelineLock.for_index(index)
        outcome = lock.retire_gone_holder(pid: pid, host: Status.host_identity) { watcher_group_gone?(pid) }
        if outcome == :cleared
          @logger.puts("[woods-watch] retired the extraction lock of stopped watcher pid #{pid} at #{index}")
        elsif LOCK_REFUSALS.key?(outcome)
          lock_left(pid, index, LOCK_REFUSALS.fetch(outcome))
        end
      rescue SystemCallError => e
        lock_left(pid, index, e.class)
      end

      # A lock naming another pid or host, or no lock at all, is not this watcher's and is left silently.
      def lock_left(pid, index, detail)
        @logger.puts("[woods-watch] left the extraction lock of stopped watcher pid #{pid} at #{index} " \
                     "in place: #{detail}")
      end

      # Retire the claim only when it still names the pid this attempt's stream reported.
      def retire_stopped_claim(index, pid)
        lease = ClaimLease.new(index)
        return unless lease.retire_stopped(pid: pid, host: Status.host_identity) { watcher_group_gone?(pid) }

        @logger.puts("[woods-watch] retired the claim of stopped watcher pid #{pid} at #{index}")
      rescue Errno::ENOENT
        nil
      rescue ClaimLease::Unavailable, SystemCallError => e
        claim_left(pid, index, e)
      end

      # Refusal messages name the next step and never the token; a system error names only its class.
      def claim_left(pid, index, error)
        detail = error.is_a?(ClaimLease::Unavailable) ? error.message : error.class
        @logger.puts("[woods-watch] left the claim of stopped watcher pid #{pid} at #{index} in place: #{detail}")
      end

      def await_group_exit(pid)
        deadline = monotonic + GROUP_EXIT_WAIT
        sleep 0.02 until watcher_group_gone?(pid) || monotonic >= deadline
      end

      # The guardian exits only after it has reaped the watcher and sent KILL to its group.
      def watcher_group_gone?(pid)
        return false if @process&.alive?

        Process.kill(0, -pid)
        only_zombies_in_group?(pid)
      rescue Errno::ESRCH
        true
      rescue Errno::EPERM
        false
      end

      # A killed member orphaned to a PID 1 that never reaps stays a zombie, and
      # a zombie still answers a signal to its group, but it has closed every
      # descriptor and cannot write. Only Linux /proc can tell; elsewhere the
      # group stays present.
      def only_zombies_in_group?(pgid)
        return false unless File.directory?('/proc/self')

        Dir.glob('/proc/[0-9]*/stat').none? do |path|
          state, _ppid, group = File.binread(path).split(') ').last.split.first(3)
          group.to_i == pgid && state != 'Z'
        rescue SystemCallError
          false
        end
      end

      def prepare_attempt
        retire_status
        @attempts += 1
        @attempt = SecureRandom.hex(16)
        @invalid = @timed_out = false
        @ready_at = nil
        @started_at = monotonic
        @protocol = Lifecycle.new(launcher: @token, attempt: @attempt, root: @root)
        @process = ManagedProcess.new(command: @command, root: @root, env: @env, events: true,
                                      launcher: @token, attempt: @attempt, shutdown_timeout: @shutdown_timeout)
        publish('starting', 'boot_pending')
      end

      def monitor_attempt
        loop do
          consume_events
          break if @stopping || @protocol.finished? || !@process.alive?

          if !@protocol.booted? && monotonic - @started_at >= @boot_timeout
            @timed_out = true
            break
          end
          raise ArgumentError, 'lifecycle stream ended while task was running' if @process.eof?

          heartbeat
          sleep 0.05
        end
        consume_events
      end

      def consume_events
        @process.read_events.each do |line|
          record = @protocol.accept(line)
          @status = SupervisionStatus.new(index: @protocol.index, token: @token) if record['event'] == 'identity'
          track_readiness(record) if record['event'] == 'startup'
          publish(@protocol.state, @protocol.reason) if @protocol.state && !%w[exit terminal].include?(record['event'])
        end
      end

      def track_readiness(record)
        @ready_at = record['state'] == 'ready' ? (@ready_at || monotonic) : nil
      end

      def retry_reason
        return if parked_outcome?
        return 'boot_timeout' if @timed_out
        return 'restart_required' if @protocol.terminal == 'restart_required' && @protocol.exit_code == 75
        return if [0, 127].include?(@protocol.exit_code)

        'child_failed'
      end

      def parked_outcome?
        @invalid || %w[already_running unsupported_environment].include?(@protocol.terminal)
      end

      def retry_after(reason)
        @failures = 0 if @ready_at && monotonic - @ready_at >= 60
        delay = @retry_delays.fetch([@failures, @retry_delays.size - 1].min)
        @failures += 1
        publish('retrying', reason, retry_at: (Time.now + delay).utc.iso8601)
        wait_until(monotonic + delay)
      end

      def park(reason)
        owner = reason == 'already_running' && @protocol.index ? ClaimLease.owner(@protocol.index) : nil
        foreign = owner && owner['host'] != Status.host_identity
        publish('parked', foreign ? 'owner_on_other_host' : reason)
        @logger.puts(owner ? claim_advice(owner, foreign) : PARKED_ADVICE)
        wait_until(Float::INFINITY)
      end

      def claim_advice(owner, foreign)
        command = ClaimLease.recovery_command(@protocol.index)
        if foreign
          "[woods-watch] #{@protocol.index} is owned by host #{owner['host']} (pid #{owner['pid']}), " \
            'which cannot be verified from here; no automatic takeover. ' \
            "First confirm that host or container no longer exists, then run: #{command}"
        else
          "[woods-watch] #{@protocol.index} is owned by pid #{owner['pid']} on this host; no automatic takeover. " \
            "Stop that owner through its supervisor; if it no longer exists, run: #{command}"
        end
      end

      def wait_until(deadline)
        until @stopping || monotonic >= deadline
          heartbeat
          sleep 0.05
        end
      end

      def monotonic
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
