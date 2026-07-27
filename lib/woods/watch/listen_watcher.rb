# frozen_string_literal: true

module Woods
  module Watch
    # Native filesystem events via the `listen` gem.
    #
    # Preferred when available: no idle CPU and sub-second latency. Woods does
    # not depend on `listen`, so {Watcher.build} only reaches for this backend
    # when the host already has it (Rails apps usually do — it's what
    # `ActiveSupport::EventedFileUpdateChecker` uses).
    #
    # Note the caveat that motivates keeping {PollingWatcher} around: native
    # events do not propagate reliably across container bind mounts, so a
    # daemon inside a dev container watching a mounted host directory can sit
    # silent while files change under it. Hosts in that position should force
    # polling rather than trust this backend.
    class ListenWatcher
      # @param root [String, Pathname] directory to watch
      # @param ignored [Array<String>] directory names/prefixes to skip
      # @param listen_class [Class] injectable for specs
      def initialize(root:, ignored: Watcher::DEFAULT_IGNORED_DIRECTORIES, listen_class: nil)
        @root = root.to_s
        @ignored = ignored
        @listen_class = listen_class || ::Listen
        # Set here rather than in #sleep_until_stopped: a `stop` arriving during
        # startup — the daemon's signal handler racing its watcher thread, which
        # they do by construction — used to be overwritten by the parking loop's
        # own initialization, leaving a watcher nothing could stop.
        @stopped = false
      end

      # Begin delivering events until {#stop}.
      #
      # `listen` reports modified, added and removed paths as three separate
      # arrays; the daemon treats them uniformly (a vanished path is resolved
      # by the extraction layer, which keys deletion on the file being gone),
      # so they are merged into one batch.
      #
      # @yieldparam changed [Array<String>] absolute paths
      # @return [void]
      def start(&on_change)
        # Only the setup is wrapped. `sleep_until_stopped` parks for the whole
        # life of the daemon, so folding it into this rescue labelled every
        # later failure — including one raised by `on_change`, i.e. by the
        # extraction itself — as "failed to start", and sent it up as a
        # WatcherError the daemon then treated as a dead backend.
        begin
          @listener = @listen_class.to(@root, ignore: ignore_patterns) do |modified, added, removed|
            batch = (modified + added + removed).uniq
            on_change.call(batch) if batch.any?
          end
          @listener.start
        rescue StandardError => e
          # inotify watch exhaustion (ENOSPC) lands here, and it is the most
          # likely failure on a large tree. {Watcher.build}'s caller falls back
          # to polling on this, which works where listen just gave up.
          raise WatcherError, "listen backend failed to start: #{e.class}: #{e.message}"
        end

        sleep_until_stopped
      end

      # @return [void]
      def stop
        @stopped = true
        @listener&.stop
      end

      private

      def ignore_patterns
        @ignored.map { |dir| %r{\A#{Regexp.escape(dir)}(/|\z)} }
      end

      # `listen` runs its own thread, so the caller's thread has to park.
      def sleep_until_stopped
        sleep(0.2) until @stopped
      end
    end
  end
end
