# frozen_string_literal: true

require_relative 'managed_process'
require_relative 'lifecycle'
require_relative 'supervision_status'
require_relative 'supervisor_reporting'

module Woods
  module Watch
    # Foreground retry owner shared by Procfile and Puma installations.
    # It never retries configuration conflicts or silently takes over ownership.
    class Supervisor # rubocop:disable Metrics/ClassLength -- retry, park and shutdown share one foreground attempt state
      include SupervisorReporting

      RETRY_DELAYS = [1, 2, 4, 8, 16, 30].freeze

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
        publish('parked', reason)
        @logger.puts('[woods-watch] restart the owner after correcting configuration; no automatic takeover')
        wait_until(Float::INFINITY)
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
