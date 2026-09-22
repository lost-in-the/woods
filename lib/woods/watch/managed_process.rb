# frozen_string_literal: true

require 'json'
require 'rbconfig'
require 'securerandom'
require_relative 'child_environment'
require_relative 'event_stream'
require_relative 'managed_cleanup'

module Woods
  module Watch
    # Owns one guardian and its private pipes. File-based PIDs never grant
    # signal authority. The guardian starts before the application bundle.
    class ManagedProcess
      include ManagedCleanup

      MAX_EVENT_BYTES = 4096

      # @param command [Array<String>] explicit application argument vector
      # @param root [String] application working directory
      # @param env [Hash] application environment
      # @param shutdown_timeout [Numeric] graceful shutdown seconds
      # @param events [Boolean] expose the private task protocol to the child
      # @param launcher [String] launcher identity
      # @param attempt [String] fresh attempt identity
      # rubocop:disable-next Metrics/ParameterLists -- the process and protocol identities are explicit collaborators
      def initialize(command:, root:, env:, shutdown_timeout: 10, events: false,
                     launcher: SecureRandom.hex(16), attempt: SecureRandom.hex(16))
        @config = { command: command, root: root, env: ChildEnvironment.build(ENV.to_h.merge(env), root: root),
                    shutdown_timeout: shutdown_timeout,
                    events: events, launcher: launcher, attempt: attempt }
        @io_mutex = Mutex.new
        @stop_mutex = Mutex.new
        @pending_events = []
      end

      # @return [Integer, nil] owned guardian PID
      attr_reader :pid

      # @return [ManagedProcess] this started process
      def start
        raise ArgumentError, 'process already started' if @pid

        parent, @liveness = IO.pipe
        @reader, writer = IO.pipe
        config_reader, config_writer = IO.pipe
        spawn_guardian(parent, writer, config_reader)
        @stream = EventStream.new(reader: @reader, guardian: @pid,
                                  launcher: @config[:launcher], attempt: @config[:attempt])
        [parent, writer, config_reader].each(&:close)
        config_writer.write(JSON.generate(child_config))
        config_writer.close
        await_registration
        self
      rescue StandardError
        [parent, writer, config_reader, config_writer].compact.each { |io| io.close unless io.closed? }
        close
        raise
      end

      # @return [Boolean] guardian still owns an active attempt
      def alive?
        return false unless @pid
        return false if @status

        @status = Process.waitpid2(@pid, Process::WNOHANG)&.last
        @status.nil?
      rescue Errno::ECHILD
        false
      end

      # @return [Integer, nil] observed guardian exit code
      def exit_status
        alive?
        @status&.exitstatus
      end

      # @return [Array<String>] bounded complete private protocol records
      def read_events
        @io_mutex.synchronize do
          pending = @pending_events
          @pending_events = []
          pending + (@stream ? @stream.read : [])
        end
      end

      # @return [Boolean] private stream ended
      def eof?
        @stream&.eof? == true
      end

      # Stop only this owned group, with cleanup delegated to its guardian.
      # @return [void]
      def stop
        @stop_mutex.synchronize { stop_owned }
      end

      # Drop ownership; guardian observes EOF even if application boot hangs.
      # @return [void]
      def close
        @io_mutex.synchronize do
          [@liveness, @reader].compact.each { |io| io.close unless io.closed? }
        end
      end

      private

      def await_registration
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
        loop do
          @pending_events.concat(@stream.read)
          if @stream.child_pid
            @liveness.write('S')
            return
          end
          raise ArgumentError, 'guardian could not register its child' unless alive?
          if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
            raise ArgumentError,
                  'guardian registration timed out'
          end

          sleep 0.01
        end
      end

      def spawn_guardian(parent, writer, config_reader)
        guardian = File.expand_path('guardian.rb', __dir__)
        @pid = Process.spawn({ 'RUBYOPT' => nil, 'RUBYLIB' => nil }, RbConfig.ruby, '--disable-gems', guardian,
                             3 => writer, 4 => parent, 5 => config_reader, in: File::NULL,
                             pgroup: true, close_others: true)
      end

      def child_config
        config = @config.dup
        env = config[:env].dup
        if config[:events]
          env.merge!('WOODS_WATCH_EVENT_FD' => '3', 'WOODS_WATCH_LAUNCHER_TOKEN' => config[:launcher],
                     'WOODS_WATCH_ATTEMPT_TOKEN' => config[:attempt])
        end
        config.merge(env: env, owner_pid: Process.pid)
      end
    end
  end
end
