# frozen_string_literal: true

module Woods
  module Coordination
    # One answer to "is the process that wrote this record still running?",
    # shared by every reader that judges a recorded pid: the pipeline lock, the
    # watch status and claim files, supervision records and the MCP task store.
    #
    # Four answers, because a boolean conflates the two that need different
    # handling:
    #
    # | signal 0 | /proc/<pid>/status (Linux) | recorded host | answer   |
    # |----------|----------------------------|---------------|----------|
    # | ESRCH    | (not read)                 | this host     | :dead    |
    # | ok       | `State: Z`                 | this host     | :zombie  |
    # | ok       | any other state            | this host     | :alive   |
    # | ok       | unreadable, or not Linux   | this host     | :alive   |
    # | EPERM    | `State: Z`                 | this host     | :zombie  |
    # | EPERM    | any other state            | this host     | :alive   |
    # | EPERM    | unreadable, or not Linux   | this host     | :unknown |
    # | (not sent) | (not read)               | another host  | :unknown |
    # | (not sent) | (not read)               | not a pid     | :unknown |
    #
    # * **zombie** — the process exited but its parent has not reaped it. A
    #   writer re-parented to a PID 1 that never reaps (a container without an
    #   init) stays one after it is killed, and signal 0 still succeeds for it.
    #   It is as finished as a dead one.
    # * **unknown** — no evidence either way. EPERM proves a process holds the
    #   pid, but without a readable status it may be a zombie; a pid recorded
    #   on another host names a slot in a namespace this process cannot see.
    #
    # Callers decide what unknown means for them. The rule they share: unknown
    # alone never justifies taking over or discarding someone else's work. An
    # age or heartbeat rule still can.
    module Liveness
      STATES = %i[alive dead zombie unknown].freeze

      # Marker for {.check}'s +host:+ when the pid is known to be local.
      LOCAL = Object.new.freeze

      # @param pid [Integer] the recorded pid
      # @param host [String, nil, LOCAL] the host the record names. {LOCAL}
      #   (the default) skips the comparison, for a caller that has already
      #   established the pid is local. nil — a record that names no host —
      #   cannot be placed and is unknown.
      # @param local_host [String, nil] this process's host identity; required
      #   whenever +host+ is not {LOCAL}
      # @return [Symbol] one of {STATES}
      def self.check(pid, host: LOCAL, local_host: nil)
        return :unknown unless pid.is_a?(Integer) && pid.positive?
        return :unknown unless host.equal?(LOCAL) || same_host?(host, local_host)

        signal_state(pid)
      end

      # Whether a {.check} answer is evidence the process is gone.
      #
      # @param state [Symbol]
      # @return [Boolean]
      def self.gone?(state)
        %i[dead zombie].include?(state)
      end

      # @return [Boolean] true only when both identities are known and equal
      def self.same_host?(host, local_host)
        !host.nil? && !local_host.nil? && local_host != 'unknown' && host == local_host
      end
      private_class_method :same_host?

      # Signal 0 asks "could I signal this process?" without sending anything.
      def self.signal_state(pid)
        Process.kill(0, pid)
        proc_state(pid) == 'Z' ? :zombie : :alive
      rescue Errno::ESRCH
        :dead
      rescue Errno::EPERM
        case proc_state(pid)
        when 'Z' then :zombie
        when nil then :unknown
        else :alive
        end
      end
      private_class_method :signal_state

      # @param pid [Integer]
      # @return [String, nil] the one-letter state from Linux /proc, or nil
      #   when it cannot be read (or this is not Linux). Read as bytes: the
      #   `Name:` line holds the process name, which need not be ASCII or
      #   valid UTF-8.
      def self.proc_state(pid)
        return unless RUBY_PLATFORM.include?('linux')

        File.binread("/proc/#{pid}/status")[/^State:\s*(\S)/n, 1]
      rescue SystemCallError, IOError
        nil
      end
      private_class_method :proc_state
    end
  end
end
