# frozen_string_literal: true

require_relative '../change_set'
require_relative '../coordination/pipeline_lock'
require_relative '../atomic_file'
require_relative '../generation'
require_relative '../reload_policy'
require_relative 'status'
require_relative 'tree_scan'
require_relative 'watcher'
require 'json'
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
    # ## Startup is not a clean slate
    #
    # A daemon that only reacts to events it personally witnessed is stale the
    # moment it starts: edits and pulled commits that landed while nothing was
    # watching are invisible to it forever. That matters because callers stand
    # down when a daemon is alive ({Status#alive?}), so "a daemon is running"
    # has to mean "these changes are covered". {#run} therefore reconciles
    # against the index's own watermark before waiting for its first event.
    #
    # ## Placement
    #
    # Every collaborator is injected, so this class doesn't care whether it
    # runs as a dedicated process (`rake woods:watch`), inside an existing
    # dev-server process, or driven a batch at a time by a host that owns its
    # own loop. {#process} is the whole cycle for one batch and is safe to
    # call directly — which is how the specs drive it, and how an embedded
    # host would. It also drains anything a previous cycle carried forward, so
    # an embedded caller gets the same retry behaviour {#run} does.
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

      # How often an otherwise idle daemon re-stamps its status file.
      #
      # {Status#alive?} disbelieves a record older than {Status::STALE_AFTER},
      # and cycle boundaries are the only other thing that writes one — so
      # without a heartbeat a *healthy* daemon reads as dead after a quiet
      # quarter-hour, which is the single most common state for a worktree
      # nobody is typing in. Callers would then stop standing down and start
      # contending for its lock. A third of the window leaves room for two
      # missed beats.
      HEARTBEAT_INTERVAL = Status::STALE_AFTER / 3.0

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
      # @param lock [Woods::Coordination::PipelineLock, nil] writer lock for
      #   this index; built from {LOCK_NAME} when nil
      # @param catch_up [Boolean] reconcile changes that predate startup
      # @param force_polling [Boolean] never use the `listen` backend — the
      #   right choice across a container bind mount, where native FS events
      #   do not propagate
      # @param logger [#info, #warn, #error]
      # rubocop:disable Metrics/ParameterLists -- every collaborator is
      # injectable on purpose; that is what makes the daemon placement-agnostic
      # and drivable from a spec without Rails.
      def initialize(output_dir:, root: nil, extractor_factory: nil, reloader: nil, watcher: nil,
                     policy: ReloadPolicy.new, debounce: DEFAULT_DEBOUNCE,
                     full_extraction_threshold: DEFAULT_FULL_EXTRACTION_THRESHOLD,
                     idle_timeout: nil, lock: nil, catch_up: true, force_polling: false, logger: nil)
        @output_dir = output_dir.to_s
        @root = (root || (defined?(Rails) ? Rails.root : Dir.pwd)).to_s
        @extractor_factory = extractor_factory || -> { Woods::Extractor.new(output_dir: @output_dir) }
        @reloader = reloader || RailsReloader.new
        @watcher = watcher
        @policy = policy
        @debounce = debounce
        @full_extraction_threshold = full_extraction_threshold
        @idle_timeout = idle_timeout
        @catch_up = catch_up
        @force_polling = force_polling
        @logger = logger || default_logger
        @generation = Generation.new(output_dir: @output_dir)
        @status = Status.new(output_dir: @output_dir)
        @lock = lock || default_lock
        reset_cycle_state
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
        heartbeat = start_heartbeat(watcher)

        catch_up(watcher)
        start_watching(watcher) do |paths|
          enqueue(paths)
          drain(watcher)
        end

        @stop_reason || :stopped
      ensure
        heartbeat&.kill
        persist_pending
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
      # @param paths [Array<String>] changed paths, absolute or root-relative.
      #   Anything a previous cycle carried forward is folded in.
      # @return [Hash] `{ action:, state:, generation:, reason:, count:,
      #   duration_ms: }`
      def process(paths = [])
        change_set = ChangeSet.new(paths: drain_with(paths), root: @root)

        case required_action(change_set)
        when :ignore then nothing_to_do
        when :restart then require_restart(change_set)
        when :reload then attempt_reload ? extract(change_set) : degraded_reload(change_set)
        else extract(change_set)
        end
      end

      private

      # What this batch demands, with one escalation applied: an app that cannot
      # reload at all (`config.enable_reloading = false` — the production
      # default, and common in staging-shaped dev containers) can only honour a
      # `:reload` by restarting, since extracting against constants that no
      # longer match their source is the thing the classification exists to
      # prevent.
      def required_action(change_set)
        action = @policy.classify_all(change_set.relative_paths)
        return :restart if action == :reload && !@reloader.enabled?

        action
      end

      # An all-ignorable batch is not evidence that a previously degraded
      # condition cleared — nothing was retried, so nothing was proven. Flipping
      # back to `running` here would advertise a healthy index while the reload
      # that failed is still failing.
      def nothing_to_do
        outcome(:ignore, @degraded_reason ? :degraded : :running, reason: @degraded_reason)
      end

      def default_lock
        Coordination::PipelineLock.new(
          lock_dir: @output_dir, name: LOCK_NAME, stale_timeout: LOCK_STALE_TIMEOUT
        )
      end

      def reset_cycle_state
        @pending = Set.new
        @pending_mutex = Mutex.new
        @stop_reason = nil
        @drain_mutex = Mutex.new
      end

      # Wait out the debounce window so events that land during it join the
      # same cycle.
      #
      # This only coalesces because the watcher callback merges into `@pending`
      # and returns immediately ({#enqueue}) rather than processing inline —
      # so a save, the formatter's rewrite, and the linter's touch accumulate
      # here and {#process} drains all three as one batch. Sleeping alone would
      # just delay the first of three cycles.
      def settle
        sleep(@debounce) if @debounce.to_f.positive?
      end

      # Merge a watcher batch into the pending set without processing it.
      def enqueue(paths)
        absolute = ChangeSet.new(paths: paths, root: @root).absolute_paths
        @pending_mutex.synchronize { @pending.merge(absolute) }
        @last_event_at = monotonic_now
      end

      # Fold in anything a previous cycle could not process.
      #
      # A cycle skipped for lock contention, a failed reload, or a raising
      # extraction must not lose its paths — the files really did change, and
      # no later event will mention them again. They ride along with the next
      # batch instead.
      def drain_with(paths)
        @pending_mutex.synchronize do
          carried = @pending.to_a
          @pending = Set.new
          carried.empty? ? Array(paths) : (carried + Array(paths)).uniq
        end
      end

      def carry_forward(change_set)
        @pending_mutex.synchronize { @pending.merge(change_set.absolute_paths) }
      end

      # Run cycles until the pending set is empty. One call per watcher batch;
      # re-entrant calls return immediately so listen's thread pool cannot run
      # two cycles against one index.
      #
      # `try_lock`, not a boolean: check-then-set on an ivar is exactly the
      # race it is guarding against — two callback threads could both read
      # `false` before either wrote `true` and run two overlapping drains. The
      # loser's paths are already in `@pending` (the callback enqueues before
      # calling here), so the winner's loop picks them up; nothing is lost by
      # returning. `try_lock` also returns false on same-thread re-entry, so a
      # synchronous callback fired from inside a cycle cannot deadlock.
      def drain(watcher)
        return unless @drain_mutex.try_lock

        begin
          drain_cycles(watcher)
        ensure
          # An extraction is work, not idleness. Stamping only on the event
          # would let a cycle longer than `idle_timeout` read as a quiet
          # daemon and stop the watcher mid-run.
          @last_event_at = monotonic_now
          @drain_mutex.unlock
        end
      end

      def drain_cycles(watcher)
        until pending_empty? || @stop_reason
          settle
          result = process

          if result[:action] == :restart
            watcher.stop
            break
          end
          # A degraded cycle deliberately carried its paths forward. Retrying
          # them in a tight loop would spin on a failure that needs an edit to
          # clear, so wait for the next event.
          break if result[:state] == :degraded
        end
      end

      def pending_empty?
        @pending_mutex.synchronize { @pending.empty? }
      end

      # Reconcile changes that predate this daemon.
      #
      # The generation file is rewritten as the last act of every successful
      # extraction, so its mtime is "when this index was last known good".
      # Anything modified since is uncovered, whoever made the change and
      # whether or not a daemon was watching at the time. With no generation
      # file at all there is no index, and every file is uncovered — which the
      # storm threshold correctly turns into one full extraction.
      # Carry the pending set across a restart.
      #
      # Within a run, carried paths survive; at shutdown they were dropped, and
      # recovery fell to the mtime watermark — which does not cover them. If
      # another writer bumps the generation *after* the daemon carried a path
      # forward, the watermark is newer than the file's mtime and catch-up skips
      # it: the change is lost for good while the status says `running`.
      # Sequence: save `user.rb`; a hook sync holds the lock; the daemon's cycle
      # contends and carries it; the hook finishes and bumps; the daemon stops.
      def persist_pending
        paths = @pending_mutex.synchronize { @pending.to_a }
        return AtomicFile.write(pending_path, JSON.generate([])) if paths.empty?

        @logger.info("[Woods] watch: persisting #{paths.size} unindexed path(s) for the next run")
        AtomicFile.write(pending_path, JSON.generate(paths))
      rescue StandardError => e
        @logger.warn("[Woods] watch: could not persist pending paths — #{e.message}")
      end

      # Paths a previous run owed, reloaded at startup so catch-up covers them
      # regardless of what the watermark says.
      def restore_pending
        return [] unless File.exist?(pending_path)

        paths = JSON.parse(AtomicFile.read(pending_path))
        return [] unless paths.is_a?(Array) && paths.any?

        @logger.info("[Woods] watch: #{paths.size} path(s) carried over from the previous run")
        paths.grep(String)
      rescue StandardError
        []
      end

      def pending_path
        File.join(@output_dir, 'watch_pending.json')
      end

      def catch_up(watcher)
        return unless @catch_up

        carried = restore_pending
        paths = (uncovered_paths + carried).uniq
        if paths.empty?
          return reconcile_deletions if stale_deletions?

          return @logger.info('[Woods] watch: index is current at startup')
        end

        @logger.info("[Woods] watch: #{paths.size} path(s) changed before startup — catching up")
        enqueue(paths)
        drain(watcher)
      end

      # A file deleted while nothing was watching leaves no mtime for the scan
      # to see — {TreeScan} only walks files that exist — so a deletion-only
      # downtime would log "index is current" while ghost units survive. The
      # graph knows every path it attributed a unit to; any of those gone from
      # disk means the extractor's sweep has reconciling to do.
      #
      # The daemon only *detects*; it does not name the paths. Naming them
      # would put them in the change set, whose deletions are authoritative for
      # any unit type — and some registered paths are nominal (on Rails < 7.1,
      # `ActiveRecord::SchemaMigration` registers a convention path no app
      # has), so authoritative deletion would remove units a full extraction
      # still produces. An empty-change-set run reaches the same ghosts through
      # the sweep, which carries the bounds that make it safe.
      def stale_deletions?
        root_prefix = "#{@root}/"

        persisted_registered_paths.any? do |path|
          path.start_with?(root_prefix) && !File.exist?(path)
        end
      end

      def persisted_registered_paths
        graph = File.join(@output_dir, 'dependency_graph.json')
        file_map = JSON.parse(AtomicFile.read(graph))['file_map']
        file_map.is_a?(Hash) ? file_map.keys : []
      rescue SystemCallError, JSON::ParserError
        []
      end

      def reconcile_deletions
        @logger.info('[Woods] watch: registered file(s) vanished before startup — reconciling deletions')
        extract(ChangeSet.new(paths: [], root: @root))
      end

      def uncovered_paths
        watermark = index_watermark
        TreeScan.files(root: @root, ignored: Watcher::DEFAULT_IGNORED_DIRECTORIES)
                .select { |path| uncovered?(path, watermark) }
      end

      def uncovered?(path, watermark)
        return true if watermark.nil?

        File.mtime(path).to_f > watermark
      rescue SystemCallError
        false
      end

      def index_watermark
        File.mtime(@generation.path).to_f
      rescue SystemCallError
        nil
      end

      # Keep the status file believable, and stop a dormant daemon.
      #
      # Two jobs, one timer. The heartbeat exists because {Status#alive?}
      # disbelieves an old record (see {HEARTBEAT_INTERVAL}); the idle stop
      # exists because N worktrees means N booted apps and most are dormant
      # most of the time — a slot nobody is working in should not hold ~65 MB
      # waiting to be needed, and a worktree hook or session start revives it.
      # Idle stopping is off by default; the heartbeat is not.
      #
      # @return [Thread]
      def start_heartbeat(watcher)
        Thread.new do
          loop do
            sleep(heartbeat_tick)
            break if @stop_reason

            if idle_expired?
              @logger.info("[Woods] watch: idle for #{@idle_timeout}s — exiting")
              @stop_reason = :idle
              watcher.stop
              break
            end

            restamp_status
            # A storm-triggered full extraction can outlive LOCK_STALE_TIMEOUT,
            # at which point a contender would retire the lock of a run that is
            # still going. The holder has to keep saying it is alive.
            @lock.touch if @lock.respond_to?(:touch)
            retry_pending(watcher)
          end
        end
      end

      # Retry work a degraded cycle carried forward, without waiting for a new
      # file event.
      #
      # `drain_cycles` stops on a degraded result on purpose — retrying in a
      # tight loop would spin on a cause that needs an edit to clear. But then
      # only a *new* event starts another drain, so paths carried past a
      # contending writer sit unindexed for as long as the developer happens to
      # stop typing. The heartbeat is already the right cadence for "try that
      # again": slow enough not to spin, frequent enough that a finished
      # contender is noticed in minutes rather than never.
      def retry_pending(watcher)
        return if pending_empty? || @stop_reason

        @logger.info('[Woods] watch: retrying paths carried forward from an earlier cycle')
        drain(watcher)
      end

      def heartbeat_tick
        ticks = [HEARTBEAT_INTERVAL]
        ticks << (@idle_timeout / 4.0) if @idle_timeout.to_f.positive?
        [ticks.min, 0.05].max
      end

      def idle_expired?
        return false unless @idle_timeout.to_f.positive?
        return false if @drain_mutex.locked?

        monotonic_now - @last_event_at >= @idle_timeout
      end

      # Rewrite the last published record so its timestamp stays fresh. Note it
      # republishes the *last* state rather than `:running` — a degraded daemon
      # is still degraded between events, and saying otherwise is the one thing
      # the status file exists to prevent.
      def restamp_status
        record = @last_status
        return if record.nil?

        @status.write(**record)
      rescue StandardError => e
        @logger.warn("[Woods] watch: could not refresh status — #{e.message}")
      end

      # Start the watcher, falling back to polling if the native backend cannot
      # start at all (inotify exhaustion being the usual reason). A daemon that
      # costs some CPU beats one that silently never fires.
      def start_watching(watcher, &on_change)
        watcher.start(&on_change)
      rescue WatcherError => e
        raise if @polling_fallback

        @polling_fallback = true
        @logger.warn("[Woods] watch: #{e.message} — falling back to polling")
        @watcher = Watcher.build(root: @root, logger: @logger, force_polling: true)
        @watcher.start(&on_change)
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

      # The reload failed, so the constants no longer match their source and
      # extracting now would publish introspection of a stale class graph.
      #
      # The paths still have to survive. A developer who saves a valid
      # `post.rb` while `user.rb` sits half-typed gets one app-wide reload
      # failure covering both; when `user.rb` is fixed, that event names only
      # `user.rb`, and `post.rb`'s change would never reach the index at all.
      def degraded_reload(change_set)
        carry_forward(change_set)
        outcome(:reload, :degraded, reason: @reload_error, count: change_set.size)
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
        # Acquiring is itself IO and can fail (a read-only or full output dir).
        # Outside the failure posture that raised straight through the watcher
        # callback and killed the loop.
        acquired = @lock.acquire
        return contended(change_set, started) unless acquired

        begin
          run_extraction(change_set, started)
        ensure
          @lock.release
        end
      rescue ScriptError, StandardError => e
        carry_forward(change_set)
        reason = "could not take the extraction lock: #{e.class}: #{e.message}"
        @logger.error("[Woods] watch: #{reason}")
        outcome(:extract, :degraded, reason: reason, count: change_set.size,
                                     duration_ms: elapsed_ms(started))
      end

      # Another writer holds the extraction lock — a manual `woods:extract`,
      # or a hook sync that fired anyway. Yield rather than race: the manual
      # run is doing the same job, and the daemon's paths are carried into the
      # next cycle so nothing is lost.
      def contended(change_set, started)
        carry_forward(change_set)
        reason = 'another writer holds the extraction lock — retrying on the next event'
        @logger.info("[Woods] watch: #{reason}")
        outcome(:contended, :degraded, reason: reason, count: change_set.size,
                                       duration_ms: elapsed_ms(started))
      end

      def run_extraction(change_set, started)
        # Count only paths that imply extraction work. Sixty edited markdown
        # files plus one model is a one-model change, and reading it as a storm
        # would trade a millisecond cycle for a full extraction.
        actionable = actionable_count(change_set)
        full = actionable > @full_extraction_threshold
        log_storm(actionable) if full

        before = @generation.current.number
        extractor = @extractor_factory.call
        touched = if full
                    extractor.extract_all
                    :all
                  else
                    extractor.extract_changed(change_set.absolute_paths)
                  end

        action = full ? :full : :incremental
        return unpublished(action, change_set, started) if wrote_without_publishing?(touched, before)

        publish(action, change_set, touched, started)
      rescue ScriptError, StandardError => e
        # Extraction failed, so nothing landed — the generation stays where it
        # was and the index keeps serving its last good state.
        reason = "extraction failed: #{e.class}: #{e.message}"
        @logger.error("[Woods] watch: #{reason}")
        # The paths really did change; a later event will not mention them
        # again, so carry them forward and try once the cause clears.
        carry_forward(change_set)
        outcome(:extract, :degraded, reason: reason, count: change_set.size,
                                     duration_ms: elapsed_ms(started))
      end

      def actionable_count(change_set)
        change_set.relative_paths.count { |path| @policy.classify(path) != :ignore }
      end

      # Did the extractor write units without the generation moving?
      #
      # `Extractor#publish_generation` rescues its own failures on purpose — an
      # index that landed correctly should not be thrown away because the
      # marker could not be written. But the generation *is* the freshness
      # contract: readers self-refresh on it, `woods_status` reports it, and a
      # cycle that silently fails to bump leaves every reader serving the
      # previous index while the daemon says `running`. Not raising was right;
      # not noticing was not.
      #
      # A no-op incremental deliberately does not bump, so this only fires when
      # units were actually written.
      def wrote_without_publishing?(touched, before)
        return false if touched != :all && Array(touched).empty?

        @generation.current.number == before
      end

      # The units are on disk and correct; only the marker that advertises them
      # is missing. Degraded rather than failed, and the paths ride forward so
      # the next successful cycle republishes them.
      def unpublished(action, change_set, started)
        carry_forward(change_set)
        reason = 'index written but the generation did not advance — readers will not see it'
        @logger.error("[Woods] watch: #{reason}")
        outcome(action, :degraded, reason: reason, count: change_set.size,
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

      def log_storm(actionable)
        @logger.info("[Woods] watch: #{actionable} actionable paths changed " \
                     "(> #{@full_extraction_threshold}) — full extraction instead of incremental")
      end

      # rubocop:disable Metrics/ParameterLists -- the shape of one cycle's result.
      def outcome(action, state, reason: nil, count: 0, duration_ms: nil, generation: nil, touched: nil)
        generation ||= @generation.current.number
        # Remembered so an `:ignore` batch cannot advertise recovery, and so the
        # heartbeat republishes the truth rather than `:running`.
        @degraded_reason = state == :degraded ? reason : nil
        publish_status(state, reason: reason, generation: generation,
                              last_action: action.to_s, last_batch_size: count,
                              last_duration_ms: duration_ms)

        { action: action, state: state, reason: reason, generation: generation,
          count: count, duration_ms: duration_ms, touched: touched }
      end
      # rubocop:enable Metrics/ParameterLists

      def publish_status(state, reason:, generation: nil, **details)
        record = { state: state, reason: reason,
                   generation: generation || @generation.current.number, **details }
        # Kept so the heartbeat can re-stamp exactly this record rather than
        # inventing a fresh one.
        @last_status = record
        @status.write(**record)
      rescue StandardError => e
        @logger.warn("[Woods] watch: could not write status — #{e.message}")
      end

      def build_watcher
        @watcher = Watcher.build(root: @root, logger: @logger, force_polling: @force_polling)
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
        # Whether this process can reload code.
        #
        # The two spellings are not two semantics: `enable_reloading` is
        # *defined* as `!cache_classes` from 7.1 on, so both branches compute
        # the same thing and the guard is only about which method exists (6.0
        # through 7.0 have no `enable_reloading` at all). Deliberately reading
        # the same value Rails' own finisher gates the reloader on — including
        # the case where an app never sets `cache_classes` and it stays `nil`,
        # which Rails reads as reloading-enabled and so must we.
        #
        # @return [Boolean]
        def enabled?
          return false unless defined?(Rails) && Rails.application

          config = Rails.application.config
          return config.enable_reloading if config.respond_to?(:enable_reloading)

          !config.cache_classes
        rescue StandardError
          false
        end

        # Reload the app's autoloaded constants.
        #
        # Deliberately bare. Unloading constants while other threads execute
        # autoloaded code — the embedded placement this class' doc blesses,
        # inside a dev server — needs the interlock's unload lock held, or you
        # get a `NameError` in an unrelated request or a deadlock against a
        # thread mid-autoload. `reload!` already takes it: the instance's
        # `class_unload!` calls `require_unload_lock!`, which is
        # `interlock.start_unloading`, and Rails' finisher registers that
        # callback whenever reloading is enabled. Wrapping this call in
        # `interlock.unloading` would re-acquire the same exclusive lock the
        # block below is about to take.
        #
        # `spec/integration/watch_daemon_spec.rb` pins that, so a Rails release
        # that stopped locking here fails rather than quietly needing a wrapper
        # nobody remembers to re-add.
        #
        # @return [void]
        def reload!
          Rails.application.reloader.reload!
        end
      end
    end
  end
end
