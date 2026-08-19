# frozen_string_literal: true

module ThreadHelpers
  # Capture threads spawned during the block and join them with a timeout.
  # Uses and_wrap_original to intercept Thread.new without breaking thread creation.
  #
  # A timed-out join is an error, not a shrug. `Thread#join(limit)` returns nil
  # rather than raising when the limit expires, so the original form let a
  # still-running background thread pass straight through — and the assertions
  # after it then described work that had not happened yet. That produced
  # exactly one intermittent failure under full-suite load (the
  # `pipeline_extract` lock spec, asserting the lock file was gone while the
  # thread still held it) and would otherwise have gone on failing at random,
  # now on every push to main.
  #
  # The timeout is also generous rather than tight: these threads do real work,
  # and a loaded CI runner is not a bug. Waiting longer costs nothing when the
  # thread finishes promptly, which is the normal case.
  #
  # @param timeout [Numeric] seconds to wait for each thread to finish
  # @yield block that may spawn threads
  # @raise [RuntimeError] if any spawned thread is still running at the timeout
  def wait_for_threads(timeout: 10)
    threads = []
    allow(Thread).to receive(:new).and_wrap_original do |original_method, *args, &block|
      thread = original_method.call(*args, &block)
      threads << thread
      thread
    end
    yield
    threads.each_with_index do |thread, index|
      next if thread.join(timeout)

      thread.kill
      raise "wait_for_threads: spawned thread #{index + 1}/#{threads.size} still running after " \
            "#{timeout}s. Assertions after this point would describe work that has not finished."
    end
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
