# frozen_string_literal: true

# A real process that has exited but that its parent (this spec process) has
# not reaped: a zombie. Signal 0 still succeeds for it, which is the case the
# shared liveness check exists to read correctly. Linux only, because only
# Linux /proc reports the state.
module UnreapedChild
  # Whether this platform can produce and observe one.
  SUPPORTED = RUBY_PLATFORM.include?('linux') && Process.respond_to?(:fork)

  module_function

  # @yieldparam pid [Integer] a pid in state `Z`, reaped after the block
  # @return [Object] the block's value
  def with_zombie
    pid = fork { exit!(0) }
    begin
      wait_for_zombie(pid)
      yield pid
    ensure
      Process.wait(pid)
    end
  end

  # @param pid [Integer]
  # @return [void]
  def wait_for_zombie(pid)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
    until File.binread("/proc/#{pid}/status")[/^State:\s*(\S)/n, 1] == 'Z'
      raise 'child never became a zombie' if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.01
    end
  end
end
