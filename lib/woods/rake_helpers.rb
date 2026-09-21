# frozen_string_literal: true

require 'woods/atomic_file'
require 'woods/generation'
require 'woods/git_command'

module Woods
  # Shared rake implementation, kept off the host application's Object.
  module RakeHelpers # rubocop:disable Metrics/ModuleLength -- existing task helpers grouped without changing behavior
    module_function

    # ── Multi-instance helpers (#164 phase 4) ────────────────────────────────
    #
    # Worktrees are disjoint by construction (each has its own Rails.root and
    # its own output dir), so these only ever mediate writers against the *same*
    # index: a manual rake run, a hook-triggered sync, and the watch daemon.

    # Run a block holding the extraction lock, waiting for another writer to
    # finish.
    #
    # This used to proceed *without* the lock after 30s, on the reasoning that a
    # daemon cycle is milliseconds so a longer wait meant something unusual. That
    # reasoning was wrong in the case that matters: a cycle includes a
    # storm-triggered `extract_all`, which on a large host app runs for minutes.
    # Proceeding then means two writers load `dependency_graph.json`, mutate
    # divergent copies, and the last one silently discards the other's work — then
    # bumps the generation, marking the clobbered graph fresh. Per-file atomic
    # writes do not help, because the file *set* is not atomic.
    #
    # So the wait is now generous and the failure explicit. `WOODS_LOCK_WAIT`
    # overrides it; exceeding it exits non-zero rather than corrupting the index,
    # which is the outcome a CI job or a developer can actually act on.
    # Fail the task when a run reported per-item errors (INF-4 / EXP-4).
    #
    # A printed-but-green run is invisible in the CI/cron pipelines these tasks
    # target: a revoked API key, a full vector store, or a 401 on every page
    # prints `Errors: N` and the job stays green while the index or the export
    # target rots. `woods:unblocked_sync` and `woods:obsidian` already exit 1 on
    # the same shape, and #270 fixed it for the extraction family; the embedding
    # and Notion tasks carry identical CI exposure.
    #
    # Partial progress is deliberately *not* a carve-out here. The unblocked
    # exporter has one (budget exhaustion with progress is the expected
    # cold-start shape and converges on the next run); an embedding or Notion
    # error is a genuine failure per unit and does not self-heal, so any
    # non-zero count fails.
    #
    # @param errors [Integer, Array, nil] the run's error count or error list
    # @return [void]
    def woods_exit_on_reported_errors(errors)
      # The embed indexer reports a count; the exporters report a list.
      # (`Integer#size` exists and answers 8, so this must branch on the type.)
      count = errors.is_a?(Numeric) ? errors.to_i : Array(errors).size
      return if count.zero?

      puts
      puts 'Run completed with errors — failing so CI surfaces it.'
      exit 1
    end

    def woods_with_extraction_lock(output_dir, wait: nil, raise_on_timeout: false, &block)
      # Requires first. The default wait reads a constant from the daemon, so
      # resolving it above these lines NameError'd every write task — the same
      # load-order bug as the missing require in `woods:watch`, reintroduced one
      # method over by the fix for it.
      require 'woods/coordination/pipeline_lock'
      require 'woods/coordination/lock_heartbeat'
      require 'woods/watch/daemon'

      wait ||= Float(ENV.fetch('WOODS_LOCK_WAIT', Woods::Watch::Daemon::LOCK_STALE_TIMEOUT))

      lock = Woods::Coordination::PipelineLock.new(
        lock_dir: output_dir.to_s,
        name: Woods::Watch::Daemon::LOCK_NAME,
        stale_timeout: Woods::Watch::Daemon::LOCK_STALE_TIMEOUT
      )

      woods_abort_on_lock_timeout(wait, raise_error: raise_on_timeout) unless woods_acquire_within(lock, wait)

      begin
        Woods::Coordination::LockHeartbeat.run(lock, &block)
      ensure
        lock.release
      end
    end

    # Poll for the lock until `wait` seconds have elapsed.
    #
    # Monotonic, so a clock adjustment mid-wait cannot cut the window short or
    # extend it indefinitely.
    #
    # @return [Boolean] whether the lock was acquired
    def woods_acquire_within(lock, wait)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + wait
      acquired = lock.acquire
      until acquired || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        sleep 0.25
        acquired = lock.acquire
      end
      acquired
    end

    def woods_abort_on_lock_timeout(wait, raise_error: false)
      if raise_error
        raise Coordination::LockError,
              "Another writer holds the extraction lock after #{wait}s; set WOODS_LOCK_WAIT to wait longer"
      end

      warn "ERROR: another writer has held the extraction lock for #{wait.round}s."
      warn 'Refusing to write: two concurrent writers rewrite the dependency graph from divergent'
      warn 'copies, and the loser\'s work is discarded under a generation that says "fresh".'
      warn 'Set WOODS_LOCK_WAIT to wait longer, or stop the other writer.'
      exit 1
    end

    # Is a watch daemon already maintaining this index?
    #
    # A session-start or worktree hook that fires `woods:incremental` on a tree
    # a daemon is already watching is pure duplicated work — and it contends for
    # the lock the daemon needs. Set WOODS_IGNORE_WATCH=1 to run anyway.
    #
    # Liveness alone is not coverage, and the difference matters. A `:running`
    # daemon reconciles everything modified since the index's last successful
    # publish when it starts (Daemon#catch_up), so changes that predate it are
    # covered whether or not it witnessed them — that is what makes standing down
    # safe. A `:degraded` daemon is alive but *cannot* currently update, so
    # standing down for it would report success over work nothing is doing.
    #
    # @return [Symbol] `:none`, `:running`, or `:degraded`
    def woods_daemon_coverage(output_dir)
      return :none if ENV['WOODS_IGNORE_WATCH'] == '1'

      require 'woods/watch/status'
      status = Woods::Watch::Status.new(output_dir: output_dir)
      return :none unless status.alive?

      status.read['state'] == 'degraded' ? :degraded : :running
    rescue StandardError
      :none
    end

    # Delete the index without yanking it out from under another writer (#170).
    #
    # The old `woods:clean` body was a bare rm_rf. Run mid-daemon-cycle it
    # deleted the daemon's own extraction lock, so the "writers serialize on
    # PipelineLock" invariant evaporated at the exact moment a writer was
    # mid-graph-rewrite. Now: refuse while a daemon is alive (same stand-down
    # check as `woods:incremental`; WOODS_IGNORE_WATCH=1 overrides), then take
    # the extraction lock like every other writer, delete everything EXCEPT the
    # lock file itself, and let release remove the lock last.
    #
    # The directory the published generation's payload lives in.
    #
    # Read-side tasks resolve through this rather than the output root: an index
    # publishing per-generation payloads keeps only `generation.json`, `dumps/`,
    # `payloads/` and the lock files at the root. A flat index resolves to the
    # root unchanged.
    #
    # @param output_dir [Pathname, String] index directory
    # @return [Pathname]
    def woods_payload_dir(output_dir)
      Woods::Generation.new(output_dir: output_dir).payload_dir
    end

    # @param output_dir [Pathname, String] index directory
    # @param wait [Numeric, nil] seconds to wait for the lock (default: the
    #   shared writer wait; injectable so a spec need not sit out the window)
    # @return [Symbol] `:cleaned`, or `:refused` when a live daemon is
    #   maintaining this index
    def woods_clean_index(output_dir, wait: nil)
      require 'woods/watch/daemon'

      output_dir = Pathname.new(output_dir)

      unless woods_daemon_coverage(output_dir) == :none
        warn 'ERROR: a watch daemon is maintaining this index — refusing to delete it out from under it.'
        warn 'Stop the daemon first, or set WOODS_IGNORE_WATCH=1 to clean anyway.'
        return :refused
      end

      lock_name = Woods::Watch::Daemon::LOCK_NAME
      woods_with_extraction_lock(output_dir, wait: wait) do
        woods_sweep_index_dir(output_dir, lock_name)
      end

      # Retain the stable guard and directory: another writer may already hold
      # the guard after release, before it has created its extraction.lock.
      :cleaned
    end

    # Delete every index artifact except the lock file and its transaction
    # guard. The guard lives inside the lock directory and a contender may hold
    # its flock right now — deleting it mid-sweep would split the flock across
    # two inodes and defeat the mutual exclusion it provides.
    def woods_sweep_index_dir(output_dir, lock_name)
      preserved = [
        output_dir.join("#{lock_name}.lock"),
        output_dir.join(Woods::Coordination::PipelineLock.guard_filename(lock_name))
      ]
      output_dir.children.each do |entry|
        FileUtils.rm_rf(entry) unless preserved.include?(entry)
      end
    end

    # The root containing the Rakefile that loaded this task file.
    #
    # `woods:watch_status` intentionally avoids Rails boot, so it cannot ask
    # `Rails.root` for the conventional output path. `Dir.pwd` is not a stable
    # substitute: `rake -f /app/Rakefile` and worktree launchers may invoke the
    # task from somewhere else. Rake retains the selected Rakefile even when it
    # does not chdir, which gives the same application root without loading the
    # environment.
    #
    # @return [String] absolute directory containing the active Rakefile
    def woods_task_root
      rakefile = Rake.application.rakefile
      return Rake.application.original_dir if rakefile.nil? || rakefile.empty?

      # Rake may keep this relative (`Rakefile`) after searching upward from a
      # nested invocation. At task execution its cwd is the directory it loaded
      # that relative file from. An explicit absolute `-f` is already complete.
      File.dirname(File.expand_path(rakefile))
    end

    # Changed paths across a git range, for `woods:incremental`'s CI branches.
    #
    # `git diff --name-only` split on lines corrupted three things at once: a
    # path containing a newline split into two entries; a non-ASCII path came
    # back octal-escaped inside quotes under git's default `core.quotePath`,
    # which the dispatcher then can't match to any rule; and a rename reported
    # only the new path, so the old path's unit was never pruned. `-z` +
    # `--name-status` + `--no-renames` fixes all three: NUL-delimited records,
    # `core.quotePath=false` unescaped, and a rename decomposed by git itself
    # into a separate `A <new>` and `D <old>` record rather than one `R` record
    # naming both.
    #
    # The diff is rooted at the extracted application (`git -C Rails.root`),
    # consistent with {Woods::GitProvenance} (#262): extraction launched from
    # another checkout must not diff that checkout's history.
    #
    # The child status is carried out, not discarded (M1): `Open3.capture2`
    # turned an unresolvable range — a GitLab zero-SHA, an unfetched GitHub base
    # ref, garbage — into an empty change set the caller could not tell apart
    # from "nothing changed", and `woods:incremental` exited 0 over a sync that
    # never ran.
    #
    # @param range [String] a git diff range/revision expression
    # @param root [Pathname, String] repository root the diff runs against
    # @return [Array(Array<String>, String, nil)] the changed paths (both halves
    #   of any rename included), or nil paths plus a human-readable failure when
    #   the range could not be resolved
    def woods_changed_paths_for_range(range, root: Rails.root)
      require 'open3'
      output, error, status = Open3.capture3(
        *Woods::GitCommand.argv(
          root, '-c', 'core.quotePath=false',
          'diff', '--name-status', '-z', '--no-renames', range
        )
      )
      return [woods_parse_git_diff_name_status(output), nil] if status.success?

      [nil, "#{error.strip} (git exited #{status.exitstatus})"]
    rescue SystemCallError => e
      # No git binary at all (a slim container image, git removed after
      # checkout). Errno::ENOENT out of `Open3.capture3` used to kill the task
      # with a backtrace: non-zero, so safe, but it bypassed the decision below
      # — the `:running`-daemon stand-down branch was unreachable, and the
      # operator got a stack trace instead of the remediation text. An absent
      # binary is an unresolvable range like any other (INF-12).
      [nil, "git unavailable: #{e.message}"]
    end

    # The changed-path set `woods:incremental` will process, or a stand-down.
    #
    # An explicit `CHANGED_FILES` list bypasses git entirely. Otherwise the
    # range comes from the CI environment (GitLab's before-SHA, GitHub's base
    # ref) or defaults to the last commit.
    #
    # A failed range is a decision, not a skip (M1): the changed-file set is
    # unknown, so silently extracting nothing would exit 0 over work that never
    # happened and leave CI drift unbounded. When a `:running` daemon maintains
    # the index, its start-up catch-up covers whatever changed, so standing down
    # with a printed reason is safe; a degraded daemon covers nothing, so the
    # run fails like any other uncovered case. The decision runs BEFORE the
    # task's empty-range exit — a failed range must never be mistaken for an
    # empty one.
    #
    # @param output_dir [Pathname, String] index directory, for daemon coverage
    # @return [Array<String>] changed paths
    def woods_incremental_changed_paths(output_dir)
      explicit = ENV.fetch('CHANGED_FILES', nil)
      return explicit.split(',').map(&:strip) if explicit

      range = woods_incremental_range
      changed_files, failure = woods_changed_paths_for_range(range)
      return changed_files unless failure

      if woods_daemon_coverage(output_dir) == :running
        puts "Could not resolve the git diff range #{range.inspect} (#{failure})."
        puts 'A watch daemon is maintaining this index, so its catch-up covers the changed paths — standing down.'
        puts 'To extract now anyway, repair or provide the range (check the CI env refs),'
        puts 'set CHANGED_FILES explicitly, or run a full woods:extract.'
        exit 0
      end

      warn "ERROR: could not resolve the git diff range #{range.inspect}: #{failure}"
      warn 'The changed-file set is unknown, so incremental extraction would silently index nothing.'
      warn 'Fix the range (a zero SHA or an unfetched base ref resolve to nothing), or run a full woods:extract.'
      exit 1
    end

    # The git range `woods:incremental` diffs, from the CI environment or the
    # last-commit default.
    #
    # @return [String]
    def woods_incremental_range
      if ENV['CI_COMMIT_BEFORE_SHA']
        # GitLab CI
        "#{ENV['CI_COMMIT_BEFORE_SHA']}..#{ENV.fetch('CI_COMMIT_SHA', nil)}"
      elsif ENV['GITHUB_BASE_REF']
        # GitHub Actions PR
        "origin/#{ENV['GITHUB_BASE_REF']}...HEAD"
      else
        # Default: changes since last commit
        'HEAD~1'
      end
    end

    # Parse NUL-delimited `git diff --name-status -z --no-renames` output.
    #
    # Each record is `<status>\0<path>\0` — `--no-renames` guarantees a single
    # path per record, since it is what stops git emitting a two-path `R`/`C`
    # record in the first place. Status letters are not inspected beyond "did
    # git report anything at all"; a deleted path still needs to reach the
    # change set so its unit can be pruned.
    #
    # A bare `Open3.capture2` read is tagged with the process's default
    # external encoding — US-ASCII under `LANG=C`, this daemon's usual
    # environment (see `AtomicFile.read`'s gotcha) — so a UTF-8 path is a
    # US-ASCII string containing invalid bytes until re-tagged.
    #
    # @param output [String] raw NUL-delimited git output
    # @return [Array<String>] changed paths
    def woods_parse_git_diff_name_status(output)
      fields = output.dup.force_encoding(Encoding::UTF_8).split("\x00")
      paths = []
      fields.each_slice(2) do |status, path|
        break if path.nil?

        paths << path unless status.nil? || status.empty?
      end
      paths
    end

    # Resolve the configured retrieval stack and run one ad-hoc query (#178).
    #
    # Every backend — embedding provider, vector store, metadata store, graph
    # store — is resolved through Woods::Builder from Woods.configuration,
    # the same wiring `woods:embed` writes through
    # (Woods::Tasks.build_embed_indexer). The old task body hardcoded
    # Ollama + InMemory + SQLite + Memory, so on any other configured stack it
    # queried backends the embed run never wrote to and silently returned
    # nothing.
    #
    # In-memory stores start empty in a fresh process; hosts on the :local /
    # :shared_filesystem presets should query through woods-mcp, which
    # hydrates them from the dumps on disk.
    #
    # @param query [String] natural-language retrieval query
    # @return [String] human-formatted retrieval output
    def woods_run_retrieval(query)
      require 'woods'
      require 'woods/formatting/human_adapter'

      config = Woods.configuration
      retriever = Woods::Builder.new(config).build_retriever
      result = retriever.retrieve(query, budget: config.max_context_tokens)

      Woods::Formatting::HumanAdapter.new.format(result)
    end
  end
end
