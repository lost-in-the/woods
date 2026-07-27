# frozen_string_literal: true

require 'woods'

module Woods
  module Watch
    # Raised when a watcher backend cannot be started.
    class WatcherError < Woods::Error; end

    # File-change sources for the daemon.
    #
    # Two backends, and the choice is operational rather than aesthetic:
    #
    # * {ListenWatcher} wraps the `listen` gem, which uses native FS events
    #   (inotify, FSEvents) — low latency, no idle CPU. Requires the gem,
    #   which Woods does not depend on.
    # * {PollingWatcher} scans mtimes on an interval. Slower and does real
    #   work while idle, but it needs nothing and, critically, it *works
    #   across container bind mounts* — where native events are famously
    #   unreliable (documented by `listen` itself; macOS Docker VMs are the
    #   usual casualty). Extraction typically runs inside a dev container with
    #   the source bind-mounted, so this is not an edge case.
    #
    # {.build} prefers listen and falls back, because a daemon that silently
    # never fires is worse than one that costs a little CPU.
    #
    # Every backend implements the same two methods: `start(&on_change)`,
    # which yields an array of absolute paths, and `stop`.
    module Watcher
      # Directory names never worth watching. Scanning them is what makes a
      # polling watcher expensive, and a change inside one is never extraction
      # input.
      DEFAULT_IGNORED_DIRECTORIES = %w[
        .git
        node_modules
        tmp
        log
        coverage
        vendor/bundle
        public/assets
        public/packs
        storage
      ].freeze

      module_function

      # Build the best available backend for a root.
      #
      # @param root [String, Pathname] directory to watch
      # @param ignored [Array<String>] directory names/prefixes to skip
      # @param poll_interval [Float] seconds between scans (polling backend)
      # @param force_polling [Boolean] skip the listen backend entirely
      # @param logger [#info, #warn] where backend selection is reported
      # @return [#start, #stop]
      def build(root:, ignored: DEFAULT_IGNORED_DIRECTORIES, poll_interval: 1.0,
                force_polling: false, logger: nil)
        force_polling ||= containerized?

        unless force_polling
          begin
            require 'listen'
            logger&.info('[Woods] watch: using native FS events (listen)')
            return ListenWatcher.new(root: root, ignored: ignored)
          rescue LoadError
            logger&.info('[Woods] watch: listen gem not available, polling instead')
          end
        end

        logger&.info("[Woods] watch: polling every #{poll_interval}s")
        PollingWatcher.new(root: root, ignored: ignored, interval: poll_interval)
      end

      # Are we probably inside a container?
      #
      # The failure this guards is silent and total: on a runtime where FS
      # events do not cross the bind mount, auto-preferring `listen` produces a
      # daemon that reports `running`, never fires, and keeps the index frozen
      # while claiming to maintain it. Polling on a runtime that would have
      # propagated events costs some CPU. Those are not symmetric, so the
      # ambiguous case defaults to the recoverable one.
      #
      # Deliberately a heuristic and deliberately overridable — event
      # propagation is runtime-specific (OrbStack propagates; Docker Desktop's
      # VM is the case `listen` itself documents as unreliable), so a host that
      # knows better sets `WOODS_WATCH_POLL=0`.
      #
      # @return [Boolean]
      def containerized?
        return ENV['WOODS_WATCH_POLL'] != '0' if ENV.key?('WOODS_WATCH_POLL')

        File.exist?('/.dockerenv') || File.exist?('/run/.containerenv')
      rescue StandardError
        false
      end
    end
  end
end

require_relative 'polling_watcher'
require_relative 'listen_watcher'
