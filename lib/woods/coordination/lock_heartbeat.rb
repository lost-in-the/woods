# frozen_string_literal: true

require_relative 'pipeline_lock'

module Woods
  module Coordination
    # Keeps a held {PipelineLock} fresh for the duration of a block.
    #
    # {PipelineLock} staleness is mtime-only, so a holder that goes quiet for
    # longer than `stale_timeout` has its lock retired by the next writer —
    # producing exactly the two-writer clobber the lock exists to prevent,
    # silently, with the generation bumped afterwards so the clobbered index
    # reads as fresh.
    #
    # The daemon refreshes its lock at every cycle boundary. The rake writers
    # (`woods:extract`, `woods:incremental`, `woods:refresh`) have no such
    # boundary — the work is one opaque block — so they need a thread.
    #
    # Extracted from `lib/tasks/woods.rake` rather than left as a private
    # method on `main`: a helper in a task file cannot be driven by a spec, and
    # the properties worth guarding here are its own (the block's value
    # survives, its exception survives, the thread stops, the pacing follows
    # the lock) rather than {PipelineLock}'s.
    class LockHeartbeat
      # Fraction of the stale window to wait between refreshes. A third means
      # two consecutive misses still leave the lock fresh — the same ratio
      # {Woods::Watch::Status} uses for its own heartbeat.
      INTERVAL_RATIO = 3.0

      # How often the loop wakes to re-check the stop flag. Independent of the
      # refresh interval so a short run's end is noticed promptly rather than a
      # third of the window later.
      TICK = 1.0

      # Run a block with the lock kept fresh underneath it.
      #
      # @param lock [PipelineLock] a lock this process currently holds
      # @param tick [Numeric] seconds between wakeups (injectable for specs)
      # @return [Object] whatever the block returns
      def self.run(lock, tick: TICK, &block)
        new(lock, tick: tick).run(&block)
      end

      def initialize(lock, tick: TICK)
        @lock = lock
        @tick = tick
        @interval = lock.stale_timeout / INTERVAL_RATIO
        @stop = false
      end

      # @return [Object] the block's return value
      def run
        thread = start_thread
        yield
      ensure
        @stop = true
        thread&.join(@tick + 1)
      end

      private

      def start_thread
        # A raising heartbeat must never become the caller's error. `join`
        # re-raises a thread's exception, and this `join` sits in an `ensure` —
        # so without this rescue a successful extraction would fail with the
        # heartbeat's error, and a failing one would have its real error
        # replaced by it, precisely when the real message matters most.
        thread = Thread.new do
          beat
        rescue StandardError
          nil
        end
        thread.report_on_exception = false
        thread
      end

      def beat
        # Monotonic, not a count of wakeups. The acquire loop in woods.rake uses
        # CLOCK_MONOTONIC for the same reason: across a laptop suspend the wall
        # clock advances while a wakeup counter does not, so a counted heartbeat
        # would still believe it had time left while the lock aged past the
        # window. Suspend is what actually produces multi-minute quiet periods
        # on a dev machine.
        last = now
        until @stop
          sleep(@tick)
          next if @stop || now - last < @interval

          @lock.touch
          last = now
        end
      end

      def now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
