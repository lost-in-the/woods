# frozen_string_literal: true

require 'timeout'

module Woods
  module Evaluation
    # Bounds every call an ablation trial makes to the same per-call timeout
    # (#280 review): a per-command budget applied independently to each
    # command a trial runs (worktree add/remove, the optional reset, the
    # agent invocation, the check), not one budget shared across the whole
    # trial. `AblationRunner` wraps whatever executor it is given with this
    # class exactly once, so `AblationWorktree` and the runner itself both
    # get the bound for free by calling `@executor.call` as normal.
    #
    # On timeout, `Timeout.timeout` only interrupts the calling thread; a
    # subprocess started by the wrapped executor keeps running unless
    # something kills it. When the wrapped executor exposes its most recent
    # pid (see {AblationExecutor}), this sends TERM, waits briefly, then KILL
    # if the process is still alive, before reporting the call as a timed-out
    # failure. An executor that does not expose a pid (for example a fake
    # executor in a spec) still gets the timeout, just without a process to
    # terminate.
    class AblationTimedExecutor
      TERM_GRACE_SECONDS = 2
      REAP_GRACE_SECONDS = 2
      POLL_INTERVAL = 0.05

      # @param executor [#call] `call(command, chdir:)` returning `[stdout, stderr, success]`
      # @param timeout [Numeric] seconds allowed per call
      def initialize(executor, timeout:)
        @executor = executor
        @timeout = timeout
      end

      # @return [Array(String, String, Boolean)] stdout, stderr, success
      def call(command, chdir:)
        Timeout.timeout(@timeout) { @executor.call(command, chdir: chdir) }
      rescue Timeout::Error
        ['', "timed out after #{@timeout}s#{terminate_process}", false]
      end

      private

      # @return [String] empty, or a note that the pid outlived the reap
      #   grace period, appended to the timeout message
      def terminate_process
        pid = executor_pid
        return '' unless pid

        Process.kill('TERM', pid)
        Process.kill('KILL', pid) unless process_exited?(pid, within: TERM_GRACE_SECONDS)
        reap(pid, within: REAP_GRACE_SECONDS) ? '' : " (pid #{pid} did not reap within #{REAP_GRACE_SECONDS}s)"
      rescue Errno::ESRCH, Errno::ECHILD
        ''
      end

      def executor_pid
        @executor.pid if @executor.respond_to?(:pid)
      end

      def process_exited?(pid, within:)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + within
        until Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
          begin
            Process.kill(0, pid)
          rescue Errno::ESRCH
            return true
          end
          sleep POLL_INTERVAL
        end
        false
      end

      # Polls a non-blocking wait instead of a plain Process.wait (#280
      # review, minor): a pid some other bug left un-reapable must not hang
      # the whole trial forever just because we tried to clean up after it.
      def reap(pid, within:)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + within
        until Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
          reaped_pid, = Process.wait2(pid, Process::WNOHANG)
          return true if reaped_pid

          sleep POLL_INTERVAL
        end
        false
      rescue Errno::ECHILD
        true
      end
    end
  end
end
