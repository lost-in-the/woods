# frozen_string_literal: true

require_relative '../change_set'
require_relative '../coordination/pipeline_lock'
require_relative '../generation'
require_relative '../reload_policy'
require_relative 'status'
require_relative 'watcher'
require 'set'

module Woods
  module Watch
    # A resident, booted-app process that keeps the index current as files
    # change.
    #
    # Woods' differentiating data — reflection-true associations, resolved
    # callback chains, inlined concerns — requires a booted Rails app, which
    # is why freshness has been pull-based: every sync from a cold process
    # pays a full boot, so syncing gets batched at hook points instead of
    # happening continuously. The boot requirement doesn't actually force
    # batch semantics, though. A process that stays booted and re-extracts on
    # file events gives runtime-true answers with seconds of lag. This is that
    # process.
    #
    # One cycle:
    #
    #   watch → debounce → classify → reload if needed → extract → publish
    #
    # ## Classification decides the cycle, not the file list
    #
    # {ReloadPolicy} answers "what has to happen before re-extracting is
    # truthful", and the daemon obeys it rather than re-extracting blindly:
    #
    # * `:ignore` — nothing to do; no publish, no generation bump.
    # * `:reextract` — Woods reads bytes. Extract directly.
    # * `:reload` — an autoloaded constant changed. Reload first, or the
    #   extractors introspect classes that no longer match their source.
    # * `:restart` — boot-captured state changed (initializers, `config/**`,
    #   `Gemfile.lock`, schema). Rails' reloader re-runs none of it, so the
    #   daemon stops and asks to be restarted rather than serving answers
    #   derived from a boot that no longer describes the app. This is
    #   Spring's contract, copied deliberately: Spring's staleness bugs came
    #   from under-scoping exactly this set.
    #
    # ## Failure posture
    #
    # A syntax error mid-edit is normal, not exceptional — it happens every
    # time someone saves halfway through a thought. So a failed reload is not
    # a crash: the daemon publishes a degraded {Status} naming the reason,
    # leaves the index intact at its last good generation, and tries again on
    # the next event. Nothing advances a cursor over work that didn't land,
    # and the generation is bumped only after a successful write, so a reader
    # can always tell "current" from "frozen, and here's why".
    #
    # ## Storms
    #
    # A branch switch or rebase touches hundreds of files at once. Above
    # `full_extraction_threshold`, N incremental steps cost more than one full
    # extraction and risk interleaving with a still-settling tree, so the
    # daemon falls back to a full run and logs that it did.
    #
    # ## Placement
    #
    # Every collaborator is injected, so this class doesn't care whether it
    # runs as a dedicated process (`rake woods:watch`), inside an existing
    # dev-server process, or driven a batch at a time by a host that owns its
    # own loop. {#process} is the whole cycle for one batch and is safe to
    # call directly — which is how the specs drive it, and how an embedded
    # host would.
    #
    # @example A dedicated daemon
    #   Woods::Watch::Daemon.new(output_dir: Rails.root.join("tmp/woods")).run
    #
    class Daemon # rubocop:disable Metrics/ClassLength
      # Seconds of quiet before a batch is considered settled. An editor
      # save, a formatter rewriting the file, and a linter touching it again
      # should be one cycle, not three.
      DEFAULT_DEBOUNCE = 0.4

      # Changed-file count above which a full extraction is cheaper and safer
      # than iterating.
      DEFAULT_FULL_EXTRACTION_THRESHOLD = 50

      # Name of the file lock that serializes writers within one worktree.
      # Worktrees are disjoint by construction — each has its own Rails.root
      # and its own output dir — so this only ever contends with another
      # writer against the *same* index: a manual `woods:extract`, or a hook
      # sync that fired anyway.
      LOCK_NAME = 'extraction'

      # A daemon cycle is milliseconds; a manual full extraction is seconds to
      # minutes. This bounds how long a crashed writer can block the daemon.
      LOCK_STALE_TIMEOUT = 600

      # @return [Woods::Generation]
      attr_reader :generation

      # @return [Woods::Watch::Status]
      attr_reader :status

      # @param output_dir [String, Pathname] index directory
      # @param root [String, Pathname] application root (defaults to Rails.root)
      # @param extractor_factory [#call] returns a fresh {Woods::Extractor}
      # @param reloader [#reload!, #enabled?] Rails reload adapter
      # @param watcher [#start, #stop, nil] built from config when nil
      # @param policy [Woods::ReloadPolicy]
      # @param debounce [Float] quiet window in seconds
      # @param full_extraction_threshold [Integer]
      # @param idle_timeout [Numeric, nil] stop after this many idle seconds
      # @param logger [#info, #warn, #error]
      # rubocop:disable Metrics/ParameterLists -- every collaborator is
      # injectable on purpose; that is what makes the daemon placement-agnostic
      # and drivable from a spec without Rails.
      def initialize(output_dir:, root: nil, extractor_factory: nil, reloader: nil, watcher: nil,
                     policy: ReloadPolicy.new, debounce: DEFAULT_DEBOUNCE,
                     full_extraction_threshold: DEFAULT_FULL_EXTRACTION_THRESHOLD,
                     idle_timeout: nil, lock: nil, logger: nil)
        @output_dir = output_dir.to_s
        @root = (root || (defined?(Rails) ? Rails.root : Dir.pwd)).to_s
        @extractor_factory = extractor_factory || -> { Woods::Extractor.new(output_dir: @output_dir) }
        @reloader = reloader || RailsReloader.new
        @watcher = watcher
        @policy = policy
        @debounce = debounce
        @full_extraction_threshold = full_extraction_threshold
        @idle_timeout = idle_timeout
        @logger = logger || default_logger
        @generation = Generation.new(output_dir: @output_dir)
        @status = Status.new(output_dir: @output_dir)
        @lock = lock || Coordination::PipelineLock.new(
          lock_dir: @output_dir, name: LOCK_NAME, stale_timeout: LOCK_STALE_TIMEOUT
        )
        @pending = Set.new
        @stop_reason = nil
      end
      # rubocop:enable Metrics/ParameterLists

      # Watch until stopped, a restart is required, or the idle timeout fires.
      #
      # @return [Symbol] why the loop ended — `:stopped`, `:restart_required`,
      #   or `:idle`
      def run
        watcher = @watcher || build_watcher
        publish_status(:running, reason: nil)
        @last_event_at = monotonic_now
        idle_monitor = start_idle_monitor(watcher)

        watcher.start do |paths|
          @last_event_at = monotonic_now
          settle(watcher)
          result = process(paths_since(paths))
          watcher.stop if result[:action] == :restart
        end

        @stop_reason || :stopped
      ensure
        idle_monitor&.kill
        publish_status(:stopped, reason: @stop_reason&.to_s)
      end

      # Stop the loop at the next opportunity.
      #
      # @return [void]
      def stop
        @stop_reason = :stopped
        @watcher&.stop
      end

      # Run one full cycle for a batch of changed paths.
      #
      # This is the daemon's whole behaviour; {#run} only supplies batches.
      # Calling it directly is the supported way to embed the daemon in a
      # process that owns its own event loop.
      #
      # @param paths [Array<String>] changed paths, absolute or root-relative
      # @return [Hash] `{ action:, state:, generation:, reason:, count:,
      #   duration_ms: }`
      def process(paths)
        change_set = ChangeSet.new(paths: paths, root: @root)
        action = @policy.classify_all(change_set.relative_paths)

        return outcome(:ignore, :running) if action == :ignore

        action = :restart if action == :reload && !@reloader.enabled?
        return require_restart(change_set) if action == :restart
        return outcome(:reload, :degraded, reason: @reload_error) if action == :reload && !attempt_reload

        extract(change_set)
      end

      private

      # Wait out the debounce window, draining anything that lands during it.
      # Without this, a save that triggers three events runs three cycles.
      def settle(_watcher)
        sleep(@debounce) if @debounce.to_f.positive?
      end

      # Fold in anything a previous cycle could not process.
      #
      # A cycle skipped for lock contention must not lose its paths — the
      # files really did change, and no later event will mention them again.
      # They ride along with the next batch instead.
      def paths_since(paths)
        return paths if @pending.empty?

        carried = @pending.to_a
        @pending = Set.new
        (carried + Array(paths)).uniq
      end

      # Stop the daemon after `idle_timeout` seconds without a file event.
      #
      # N worktrees means N booted apps, and most of them are dormant most of
      # the time. A slot nobody is working in should not hold ~65 MB waiting
      # to be needed; a worktree hook or session start revives it. Off by
      # default — a single-worktree host wants the daemon to stay up.
      #
      # @return [Thread, nil]
      def start_idle_monitor(watcher)
        return nil unless @idle_timeout.to_f.positive?

        Thread.new do
          loop do
            sleep([@idle_timeout / 4.0, 1.0].max)
            next if monotonic_now - @last_event_at < @idle_timeout

            @logger.info("[Woods] watch: idle for #{@idle_timeout}s — exiting")
            @stop_reason = :idle
            watcher.stop
            break
          end
        end
      end

      def attempt_reload
        @reload_error = nil
        @reloader.reload!
        true
      rescue ScriptError, StandardError => e
        # A syntax error mid-edit lands here and is completely routine. Note
        # ScriptError: SyntaxError is not a StandardError, so rescuing only
        # StandardError would let a half-typed file kill the daemon.
        @reload_error = "#{e.class}: #{e.message}"
        @logger.warn("[Woods] watch: reload failed — #{@reload_error}")
        false
      end

      def require_restart(change_set)
        triggers = @policy.paths_requiring(change_set.relative_paths, :restart)
        reason = "restart required: #{triggers.first(5).join(', ')}"
        @logger.warn("[Woods] watch: #{reason}")
        @stop_reason = :restart_required
        outcome(:restart, :degraded, reason: reason, count: change_set.size)
      end

      def extract(change_set)
        started = monotonic_now
        return contended(change_set, started) unless @lock.acquire

        begin
          run_extraction(change_set, started)
        ensure
          @lock.release
        end
      end

      # Another writer holds the extraction lock — a manual `woods:extract`,
      # or a hook sync that fired anyway. Yield rather than race: the manual
      # run is doing the same job, and the daemon's paths are carried into the
      # next cycle so nothing is lost.
      def contended(change_set, started)
        @pending.merge(change_set.absolute_paths)
        reason = 'another writer holds the extraction lock — retrying on the next event'
        @logger.info("[Woods] watch: #{reason}")
        outcome(:contended, :degraded, reason: reason, count: change_set.size,
                                       duration_ms: elapsed_ms(started))
      end

      def run_extraction(change_set, started)
        full = change_set.size > @full_extraction_threshold
        log_storm(change_set) if full

        extractor = @extractor_factory.call
        touched = if full
                    extractor.extract_all
                    :all
                  else
                    extractor.extract_changed(change_set.absolute_paths)
                  end

        publish(full ? :full : :incremental, change_set, touched, started)
      rescue ScriptError, StandardError => e
        # Extraction failed, so nothing landed — the generation stays where it
        # was and the index keeps serving its last good state.
        reason = "extraction failed: #{e.class}: #{e.message}"
        @logger.error("[Woods] watch: #{reason}")
        # The paths really did change; a later event will not mention them
        # again, so carry them forward and try once the cause clears.
        @pending.merge(change_set.absolute_paths)
        outcome(:extract, :degraded, reason: reason, count: change_set.size,
                                     duration_ms: elapsed_ms(started))
      end

      def publish(action, change_set, touched, started)
        # The extractor bumps the generation as the last write of a successful
        # run, so the daemon reads the number rather than minting a second one
        # — two bumps per cycle would make the counter lie about how many
        # times the index actually moved.
        marker = @generation.current
        duration = elapsed_ms(started)
        @logger.info("[Woods] watch: #{action} over #{change_set.size} path(s) " \
                     "in #{duration}ms → generation #{marker.number}")

        outcome(action, :running, generation: marker.number, count: change_set.size,
                                  duration_ms: duration, touched: touched)
      end

      def log_storm(change_set)
        @logger.info("[Woods] watch: #{change_set.size} paths changed " \
                     "(> #{@full_extraction_threshold}) — full extraction instead of incremental")
      end

      # rubocop:disable Metrics/ParameterLists -- the shape of one cycle's result.
      def outcome(action, state, reason: nil, count: 0, duration_ms: nil, generation: nil, touched: nil)
        generation ||= @generation.current.number
        publish_status(state, reason: reason, generation: generation,
                              last_action: action.to_s, last_batch_size: count,
                              last_duration_ms: duration_ms)

        { action: action, state: state, reason: reason, generation: generation,
          count: count, duration_ms: duration_ms, touched: touched }
      end
      # rubocop:enable Metrics/ParameterLists

      def publish_status(state, reason:, generation: nil, **details)
        @status.write(state: state, reason: reason,
                      generation: generation || @generation.current.number, **details)
      rescue StandardError => e
        @logger.warn("[Woods] watch: could not write status — #{e.message}")
      end

      def build_watcher
        @watcher = Watcher.build(root: @root, logger: @logger)
      end

      def monotonic_now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      def elapsed_ms(started)
        ((monotonic_now - started) * 1000).round
      end

      def default_logger
        defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger ? Rails.logger : NullLogger.new
      end

      # Used when there is no Rails logger — a daemon that can't log is still
      # better than one that raises on its first message.
      class NullLogger
        def info(*); end
        def warn(*); end
        def error(*); end
      end

      # Adapter over `Rails.application.reloader`, isolated so the daemon can
      # be driven without Rails in specs.
      #
      # `enabled?` matters: an app booted with `config.enable_reloading =
      # false` (the production default, and common in staging-shaped dev
      # containers) cannot reload at all. The daemon escalates `:reload` to
      # `:restart` in that case rather than extracting against constants that
      # no longer match their source.
      class RailsReloader
        # @return [Boolean] whether this process can reload code
        def enabled?
          return false unless defined?(Rails) && Rails.application

          config = Rails.application.config
          if config.respond_to?(:enable_reloading)
            config.enable_reloading
          else
            # Rails < 7.1 spells it the other way round.
            !config.cache_classes
          end
        rescue StandardError
          false
        end

        # @return [void]
        def reload!
          Rails.application.reloader.reload!
        end
      end
    end
  end
end
