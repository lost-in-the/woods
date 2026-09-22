# frozen_string_literal: true

require 'json'
require 'io/wait'

module Woods
  module Watch
    # Minimal pre-Bundler owner. EOF on its private parent pipe always stops
    # the owned application group, even while an initializer is blocked.
    class Guardian
      # @param parent [IO] private parent-liveness reader
      # @param events [IO] lifecycle writer
      # @param config [Hash] argument vector and child environment
      def initialize(parent:, events:, config:)
        @parent = parent
        @events = events
        @config = config
        @events.sync = true
        @stopping = false
      end

      # @return [Integer] application exit status, or launch failure
      def run
        %w[INT TERM].each { |signal| Signal.trap(signal) { @stopping = true } }
        report('hello')
        spawn_child
        monitor
        report('exit', code: @status&.exitstatus, signal: @status&.termsig)
        @status&.exitstatus || 1
      rescue SystemCallError => e
        report('spawn_error', reason: e.class.name.split('::').last)
        127
      ensure
        terminate_group
      end

      private

      def spawn_child
        gate, release = IO.pipe
        @child = fork do
          release.close
          @parent.close
          Process.setpgrp
          exit! 1 unless gate.read(1) == 'S'

          gate.close
          exec_child
        end
        gate.close
        report('spawned', child_pid: @child)
        release.write('S') if acknowledged?
      ensure
        release&.close unless release&.closed?
      end

      # Do not execute application code until its owner knows the child group.
      # Guardian death before acknowledgment closes the exec gate with EOF.
      def acknowledged?
        until @stopping || Process.ppid != @config.fetch('owner_pid')
          next unless @parent.wait_readable(0.05)

          return @parent.read(1) == 'S'
        end
        false
      end

      def exec_child
        options = { chdir: @config.fetch('root'), in: File::NULL, close_others: true, unsetenv_others: true }
        options[3] = @events if @config['events']
        command = @config.fetch('command')
        Process.exec(@config.fetch('env'), [command.first, command.first], *command.drop(1), **options)
      rescue SystemCallError => e
        warn "[woods-watch] child executable could not start (#{e.class})"
        exit! 127
      end

      def monitor
        until @stopping
          break if Process.ppid != @config.fetch('owner_pid')

          result = Process.waitpid2(@child, Process::WNOHANG)
          if result
            @status = result.last
            return
          end
          @stopping = true if @parent.wait_readable(0.05) && @parent.read_nonblock(1, exception: false).nil?
        end
        terminate_group
      end

      def terminate_group
        return unless @child && !@terminated

        signal_group('TERM')
        await_child
        signal_group('KILL')
        @status ||= Process.waitpid2(@child).last
        @terminated = true
      rescue Errno::ECHILD
        nil
      end

      def await_child
        deadline = monotonic + @config.fetch('shutdown_timeout')
        until @status || monotonic >= deadline
          @status = Process.waitpid2(@child, Process::WNOHANG)&.last
          sleep 0.02 unless @status
        end
      end

      def signal_group(signal)
        Process.kill(signal, -@child)
      rescue Errno::ESRCH
        nil
      end

      def monotonic
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      def report(event, **fields)
        record = { version: 1, event: event, pid: Process.pid,
                   launcher: @config['launcher'], attempt: @config['attempt'] }.merge(fields)
        @events.write(JSON.generate(record) << "\n")
      rescue Errno::EPIPE
        @stopping = true
      end
    end
  end
end

if $PROGRAM_NAME == __FILE__
  config_io = IO.for_fd(5)
  config = JSON.parse(config_io.read)
  config_io.close
  parent = IO.for_fd(4)
  events = IO.for_fd(3, 'w')
  parent.close_on_exec = true
  events.close_on_exec = true
  exit Woods::Watch::Guardian.new(parent: parent, events: events, config: config).run
end
