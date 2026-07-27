# frozen_string_literal: true

require 'set'

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
        @snapshot = nil
      end

      # Scan until {#stop}, yielding each batch of changed absolute paths.
      #
      # @yieldparam changed [Array<String>] absolute paths
      # @return [void]
      def start(&on_change)
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

      # @return [Hash{String => Integer}] path => mtime, for every watched file
      def scan
        snapshot = {}

        each_watched_path do |path|
          snapshot[path] = File.mtime(path).to_i
        rescue SystemCallError
          # Vanished between the glob and the stat — the next scan sees it as
          # removed, which is the same answer one interval later.
          next
        end

        snapshot
      end

      def each_watched_path
        Dir.glob(File.join(@root, '**', '*'), File::FNM_DOTMATCH).each do |path|
          next if File.basename(path).start_with?('.') && File.basename(path) != '.ruby-version'
          next if ignored?(path)
          next unless File.file?(path)

          yield path
        end
      end

      def ignored?(path)
        relative = path.delete_prefix("#{@root}/")
        @ignored.any? { |dir| relative == dir || relative.start_with?("#{dir}/") }
      end
    end
  end
end
