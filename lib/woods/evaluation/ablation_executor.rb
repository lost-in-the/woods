# frozen_string_literal: true

require 'timeout'

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
        spawn_child(command, chdir, stdout_w, stderr_w)
        stdout_w.close
        stderr_w.close

        # Read concurrently with the wait, not after it: a pipe holds only
        # ~64KB on Linux before a write blocks, so a child that writes more
        # than that to either stream, with nothing draining it, blocks
        # forever, and Process.wait2 alone never touches either pipe. That
        # made AblationTimedExecutor report a false timeout on a chatty
        # agent instead of ever reaching a real result.
        stdout_thread = reader_thread(stdout_r)
        stderr_thread = reader_thread(stderr_r)
        _reaped_pid, status = Process.wait2(@pid)
        [stdout_thread.value, stderr_thread.value, status.success?]
      ensure
        stdout_r&.close
        stderr_r&.close
        stdout_w&.close unless stdout_w&.closed?
        stderr_w&.close unless stderr_w&.closed?
      end

      private

      # A timeout wrapping #call can interrupt it mid-read, closing the pipe
      # out from under whichever reader thread is still blocked on it. That
      # IOError is expected and the caller already discards this call's
      # result, so it should not be reported as an unhandled thread
      # exception.
      def reader_thread(io)
        Thread.new { io.read }.tap { |thread| thread.report_on_exception = false }
      end

      # `Thread.handle_interrupt` defers the async Timeout::Error
      # AblationTimedExecutor's Timeout.timeout can raise into this thread,
      # so it cannot land between Process.spawn returning and `@pid` being
      # set (#280 review, minor): a pid lost that way could never be
      # terminated on timeout.
      def spawn_child(command, chdir, stdout_w, stderr_w)
        Thread.handle_interrupt(Timeout::Error => :never) do
          @pid = Process.spawn(command, chdir: chdir, in: File::NULL, out: stdout_w, err: stderr_w)
        end
      end
    end
  end
end
