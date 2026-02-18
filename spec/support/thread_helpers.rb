# frozen_string_literal: true

module ThreadHelpers
  # Capture threads spawned during the block and join them with a timeout.
  # Uses and_wrap_original to intercept Thread.new without breaking thread creation.
  #
  # @param timeout [Numeric] seconds to wait for each thread to finish
  # @yield block that may spawn threads
  def wait_for_threads(timeout: 2)
    threads = []
    allow(Thread).to receive(:new).and_wrap_original do |original_method, *args, &block|
      thread = original_method.call(*args, &block)
      threads << thread
      thread
    end
    yield
    threads.each { |t| t.join(timeout) }
  end

  # Poll a condition block until it returns truthy, with configurable timeout.
  # Replaces sleeps in thread-based specs with deterministic polling.
  #
  # @param timeout [Numeric] seconds before giving up
  # @param interval [Numeric] seconds between polls
  # @yield block that returns truthy when condition is met
  # @raise [RuntimeError] if timeout exceeded
  def poll_until(timeout: 5, interval: 0.01)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    loop do
      return if yield

      raise "poll_until timed out after #{timeout}s" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep(interval)
    end
  end
end
