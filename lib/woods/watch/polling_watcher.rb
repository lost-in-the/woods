# frozen_string_literal: true

require 'set'

require_relative 'tree_scan'

module Woods
  module Watch
    # Detects changes by comparing a directory tree's mtimes between scans.
    #
    # The dependency-free backend, and the one that works where native FS
    # events don't — most importantly across container bind mounts, which is
    # the common Woods deployment. It reports creations, modifications and
    # deletions alike, because it diffs two snapshots rather than listening
    # for individual events.
    #
    # Cost is one `File.mtime` per watched file per interval. The ignore list
    # is what keeps that bounded: skipping `.git`, `node_modules`, `tmp` and
    # friends takes a Rails app from "everything" to "the source tree".
    class PollingWatcher
      # @param root [String, Pathname] directory to watch
      # @param ignored [Array<String>] directory names/prefixes to skip
      # @param interval [Float] seconds between scans
      # @param sleeper [#call] injected for specs, so they need not pass time
      def initialize(root:, ignored: Watcher::DEFAULT_IGNORED_DIRECTORIES, interval: 1.0,
                     sleeper: ->(seconds) { sleep(seconds) })
        @root = root.to_s
        @ignored = ignored
        @interval = interval
        @sleeper = sleeper
        @running = false
        @stop_requested = false
        @snapshot = nil
      end

      # Scan until {#stop}, yielding each batch of changed absolute paths.
      #
      # A {#stop} that arrives before or during startup is honoured rather than
      # overwritten: the daemon's signal handler and its watcher thread race by
      # construction, and a `SIGINT` during boot used to be swallowed, leaving a
      # watcher nobody could stop.
      #
      # @yieldparam changed [Array<String>] absolute paths
      # @return [void]
      def start(&on_change)
        return if @stop_requested

        @running = true
        primed_now?

        while @running
          @sleeper.call(@interval)
          break unless @running

          changed = poll
          on_change.call(changed) if changed.any?
        end
      end

      # Stop after the current interval.
      #
      # @return [void]
      def stop
        @stop_requested = true
        @running = false
      end

      # Take the baseline the next {#poll} compares against, if it hasn't been
      # taken already.
      #
      # Separate from {#poll} so that a watcher's first cycle reports nothing:
      # announcing every file in the tree on startup would trip the daemon's
      # storm threshold on every boot.
      #
      # @return [Boolean] true when this call took the baseline
      def primed_now?
        return false unless @snapshot.nil?

        @snapshot = scan
        true
      end

      # Run one comparison and return what moved. Public so a caller can drive
      # the watcher synchronously — which is exactly what the specs do, and
      # what an embedded host that owns its own loop would do.
      #
      # The first call primes the baseline and reports nothing.
      #
      # @return [Array<String>] changed absolute paths
      def poll
        return [] if primed_now?

        previous = @snapshot
        @snapshot = scan

        added = @snapshot.keys - previous.keys
        removed = previous.keys - @snapshot.keys
        modified = (@snapshot.keys & previous.keys).reject { |path| @snapshot[path] == previous[path] }

        (added + removed + modified).sort
      end

      private

      # Full-resolution mtime *and* size, because whole-second mtimes lose real
      # modifications. Truncating to `to_i` means a write at T+0.1s recorded by
      # a poll at T+0.5s and a second write at T+0.9s produce the same stamp:
      # the next poll sees no change and no later event ever mentions the file
      # again. Save-then-formatter inside one second is entirely ordinary at the
      # default 1s interval, and ext4/APFS/XFS all carry sub-second mtimes.
      #
      # Size is the tiebreaker for the residual case — a filesystem that really
      # only offers 1s granularity (some network and container mounts), where a
      # same-second rewrite that changes length is still caught.
      #
      # @return [Hash{String => Array}] path => [mtime, size], per watched file
      def scan
        snapshot = {}

        each_watched_path do |path|
          stat = File.stat(path)
          snapshot[path] = [stat.mtime.to_f, stat.size]
        rescue SystemCallError
          # Vanished between the glob and the stat — the next scan sees it as
          # removed, which is the same answer one interval later.
          next
        end

        snapshot
      end

      def each_watched_path(&block)
        TreeScan.each_file(root: @root, ignored: @ignored, &block)
      end
    end
  end
end
