# frozen_string_literal: true

module Woods
  module Evaluation
    # Default executor for {AblationRunner}: spawns a real subprocess and
    # exposes the pid of the most recent spawn via {#pid} (#280 review), so
    # {AblationTimedExecutor} can terminate it on timeout. `Open3.capture3`
    # blocks synchronously and never surfaces a pid to the caller, which is
    # exactly the gap that let a timed-out agent keep running in the
    # background.
    class AblationExecutor
      # @return [Integer, nil] the pid of the most recently spawned process
      attr_reader :pid

      # @param command [String] a full shell command line
      # @param chdir [String]
      # @return [Array(String, String, Boolean)] stdout, stderr, success
      def call(command, chdir:)
        stdout_r, stdout_w = IO.pipe
        stderr_r, stderr_w = IO.pipe
        @pid = Process.spawn(command, chdir: chdir, in: File::NULL, out: stdout_w, err: stderr_w)
        stdout_w.close
        stderr_w.close
        _reaped_pid, status = Process.wait2(@pid)
        [stdout_r.read, stderr_r.read, status.success?]
      ensure
        stdout_r&.close
        stderr_r&.close
        stdout_w&.close unless stdout_w&.closed?
        stderr_w&.close unless stderr_w&.closed?
      end
    end
  end
end
