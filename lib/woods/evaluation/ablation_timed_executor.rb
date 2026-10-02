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
    # pid (see {AblationExecutor}), this sends TERM, waits up to
    # {TERM_GRACE_SECONDS} for the target to exit, then KILL if still alive.
    # The default executor owns a process group, so cleanup includes
    # ordinary descendants even if their parent already exited.
    # Custom executors exposing only a pid retain single-process cleanup.
    # Cleanup finishes before reporting the call as a timed-out
    # failure. An executor that does not expose a pid (for example a fake
    # executor in a spec) still gets the timeout, just without a process to
    # terminate.
    class AblationTimedExecutor
      TERM_GRACE_SECONDS = 2
      REAP_GRACE_SECONDS = 2
      POLL_INTERVAL = 0.05
      PROC_ROOT = '/proc'

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

      # TERM; one poll loop until the TERM-grace deadline that reaps the owned
      # pid as soon as it exits and probes the signal target; KILL for
      # whatever is left; a final bounded reap.
      #
      # Reaping inside the loop matters (F10): the timeout interrupted the
      # wrapped executor's own Process.wait2, so a leader that died to the
      # TERM is a zombie, and a zombie still answers kill(0) for its group,
      # which used to spend the whole grace on a process that was already
      # dead. The same goes for a descendant the dead leader orphaned: it is
      # init's to reap, not ours, so on Linux the probe reads the group's
      # members from /proc and ignores the ones already in state Z. Probing
      # until the original deadline matters too: a TERM-compliant descendant
      # of a leader that exited at once keeps its grace to shut down cleanly
      # instead of being KILLed on the spot.
      #
      # @return [String] empty, or a note that the pid outlived the reap
      #   grace period, appended to the timeout message
      def terminate_process
        pid = executor_pid
        return '' unless pid

        target = signal_target(pid)
        signal('TERM', target)
        exited, reaped = wait_for_exit(pid, target, deadline: monotonic + TERM_GRACE_SECONDS)
        signal('KILL', target) unless exited
        reaped ||= reap_within?(pid, REAP_GRACE_SECONDS)
        reaped ? '' : " (pid #{pid} did not reap within #{REAP_GRACE_SECONDS}s)"
      rescue Errno::ESRCH, Errno::ECHILD
        ''
      end

      def executor_pid
        pid = @executor.pid if @executor.respond_to?(:pid)
        pid if pid.is_a?(Integer) && pid.positive?
      end

      # A group created by spawn(pgroup: true) is named after that child.
      # Never infer a group from a custom pid or signal our own group.
      def signal_target(pid)
        group = @executor.process_group_id if @executor.respond_to?(:process_group_id)
        group == pid && group != Process.getpgrp ? -group : pid
      end

      # A signal the kernel refuses (EPERM) is swallowed like a vanished
      # target: the bounded waits and the final reap note still bound the
      # call, where an exception would abort the whole ablation run.
      def signal(name, target)
        Process.kill(name, target)
      rescue Errno::ESRCH, Errno::EPERM
        nil
      end

      # @return [Array(Boolean, Boolean)] whether the target exited before
      #   the deadline, and whether the owned pid was reaped meanwhile
      def wait_for_exit(pid, target, deadline:)
        reaped = false
        loop do
          reaped ||= reaped?(pid)
          return [true, reaped] unless alive?(target)
          return [false, reaped] if monotonic >= deadline

          sleep POLL_INTERVAL
        end
      end

      # A probe the kernel refuses (EPERM, seen on macOS) counts as alive:
      # the loop then runs out the grace and KILLs, instead of raising. A
      # group whose only remaining members are zombies counts as exited.
      def alive?(target)
        Process.kill(0, target)
        target.negative? ? live_group_member?(-target) : true
      rescue Errno::ESRCH
        false
      rescue Errno::EPERM
        true
      end

      # Whether any member of the group is not a zombie. Only /proc (Linux)
      # can answer; elsewhere every member the kernel still lists counts,
      # which is the pre-F10 behaviour and correct wherever init reaps
      # orphans promptly.
      def live_group_member?(pgid)
        return true unless File.directory?(PROC_ROOT)

        Dir.glob("#{PROC_ROOT}/[0-9]*/stat").any? do |stat_path|
          state, group = process_state(stat_path)
          group == pgid && !%w[Z X].include?(state)
        end
      end

      # The state and process-group fields of one /proc/<pid>/stat line,
      # read after the parenthesised command name (which may itself contain
      # spaces or parentheses). A process that vanished mid-scan yields nils.
      def process_state(stat_path)
        stat = File.read(stat_path)
        fields = stat[(stat.rindex(')') + 2)..].split
        [fields[0], fields[2].to_i]
      rescue SystemCallError, IOError, TypeError
        [nil, nil]
      end

      # Non-blocking reap of the owned pid. ECHILD (not our child, or
      # already collected by the wrapped executor) counts as reaped: there
      # is nothing left for us to collect.
      def reaped?(pid)
        reaped_pid, = Process.wait2(pid, Process::WNOHANG)
        !reaped_pid.nil?
      rescue Errno::ECHILD
        true
      end

      # Polls a non-blocking wait instead of a plain Process.wait (#280
      # review, minor): a pid some other bug left un-reapable must not hang
      # the whole trial forever just because we tried to clean up after it.
      def reap_within?(pid, seconds)
        deadline = monotonic + seconds
        until monotonic >= deadline
          return true if reaped?(pid)

          sleep POLL_INTERVAL
        end
        false
      end

      def monotonic
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
