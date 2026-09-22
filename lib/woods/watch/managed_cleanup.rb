# frozen_string_literal: true

module Woods
  module Watch
    # Bounded, idempotent cleanup of groups registered by an owned guardian.
    module ManagedCleanup
      private

      def stop_owned
        return if @stopped

        @io_mutex.synchronize { @liveness.close if @liveness && !@liveness.closed? }
        wait_until_stopped(@config[:shutdown_timeout] + 1)
        force_stop if alive? || @status&.signaled?
        @stopped = true
      ensure
        close
      end

      def force_stop
        child = @stream&.child_pid
        signal_owned_group('KILL', child) if child
        signal_owned_group('KILL', @pid) if alive?
        wait_until_stopped(1)
      end

      def wait_until_stopped(seconds)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
        while alive? && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
          drain_cleanup_events
          sleep 0.02
        end
      end

      def drain_cleanup_events
        read_events
      rescue ArgumentError
        @io_mutex.synchronize { @reader.close unless @reader.closed? }
      end

      def signal_owned_group(signal, pid)
        Process.kill(signal, -pid)
      rescue Errno::ESRCH
        nil
      end
    end
  end
end
