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
      # Optional daemon handshake; called once detection is established.
      attr_writer :ready_callback

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
      # A stop is final: once {#stop} has run, `start` registers nothing, and
      # a stop racing the setup below leaves no listener running.
      #
      # @yieldparam changed [Array<String>] absolute paths
      # @return [void]
      def start(&on_change)
        return if @stopped

        # Only the setup is wrapped (in #start_listener). `sleep_until_stopped`
        # parks for the whole life of the daemon, so folding it into that
        # rescue labelled every later failure — including one raised by
        # `on_change`, i.e. by the extraction itself — as "failed to start",
        # and sent it up as a WatcherError the daemon then treated as a dead
        # backend.
        listener = start_listener(&on_change)
        return unless listener

        # {#stop} sets the flag before it reads @listener, so a stop that
        # raced `listener.start` has either stopped it or is seen here.
        stop_listener(listener) if @stopped
        sleep_until_stopped
      end

      # @return [void]
      def stop
        @stopped = true
        stop_listener(@listener)
      end

      private

      # Build, register and start the listener.
      #
      # @return [Object, nil] the started listener, or nil when a stop landed
      #   during setup and nothing was started
      # @raise [WatcherError] when the backend cannot start
      def start_listener(&on_change)
        listener = @listen_class.to(@root, ignore: ignore_patterns) do |modified, added, removed|
          batch = (modified + added + removed).uniq
          on_change.call(batch) if batch.any?
        end
        @listener = listener
        # A stop that ran before the assignment above found no listener to
        # stop; one that ran after it already stopped this one. Either way it
        # must not be started.
        return if @stopped

        listener.start
        @ready_callback&.call
        listener
      rescue StandardError => e
        # A stop that landed between the check above and `start` stopped the
        # listener first, and listen refuses to start a stopped listener. That
        # is the requested stop, not a backend that failed.
        return if @stopped

        # inotify watch exhaustion (ENOSPC) lands here, and it is the most
        # likely failure on a large tree. {Watcher.build}'s caller falls back
        # to polling on this, which works where listen just gave up.
        raise WatcherError, "listen backend failed to start: #{e.class}: #{e.message}"
      end

      # Best-effort: when {#start} and {#stop} race, both may stop the same
      # listener, and listen refuses to stop one twice.
      def stop_listener(listener)
        listener&.stop
      rescue StandardError
        nil
      end

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
