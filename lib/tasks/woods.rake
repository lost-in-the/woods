# frozen_string_literal: true

# lib/tasks/woods.rake
#
# Rake tasks for codebase indexing.
# These can be run manually or integrated into CI pipelines.
#
# Usage:
#   bundle exec rake woods:extract          # Full extraction
#   bundle exec rake woods:incremental      # Changed files only
#   bundle exec rake woods:extract_framework # Rails/gem sources only
#   bundle exec rake woods:validate          # Validate index integrity
#   bundle exec rake woods:stats             # Show index statistics
#   bundle exec rake woods:clean             # Remove index
#   bundle exec rake woods:self_analyze      # Analyze gem's own source
#   bundle exec rake woods:flow[EntryPoint]  # Generate execution flow

# Reading Woods JSON artifacts with a bare File.read tags the result with the
# process's default external encoding — US-ASCII under LANG=C, the common
# case in CI and Docker — so a non-ASCII byte (e.g. a git branch name in the
# manifest) raises Encoding::InvalidByteSequenceError. AtomicFile.write is
# binmode, so the read side must go through AtomicFile.read to match.
require 'woods/atomic_file'
require 'woods/generation'

namespace :woods do
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
  def woods_with_extraction_lock(output_dir, wait: nil, &block)
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

    woods_abort_on_lock_timeout(wait) unless woods_acquire_within(lock, wait)

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

  def woods_abort_on_lock_timeout(wait)
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

    # The lock was released (and its file removed) above; drop the guard so
    # the directory can empty, then remove the now-empty directory. Another
    # writer may legitimately have recreated content between release and here
    # — a non-empty directory is left alone rather than forced.
    woods_remove_if_empty(output_dir, lock_name)
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

  def woods_remove_if_empty(output_dir, lock_name)
    FileUtils.rm_f(output_dir.join(Woods::Coordination::PipelineLock.guard_filename(lock_name)))
    Dir.rmdir(output_dir)
  rescue SystemCallError
    nil
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
  # @param range [String] a git diff range/revision expression
  # @return [Array<String>] changed paths, both halves of any rename included
  def woods_changed_paths_for_range(range)
    require 'open3'
    output, = Open3.capture2(
      'git', '-c', 'core.quotePath=false', 'diff', '--name-status', '-z', '--no-renames', range
    )
    woods_parse_git_diff_name_status(output)
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

  desc 'Full extraction of codebase for indexing'
  task extract: :environment do
    require 'woods/extractor'

    output_dir = ENV.fetch('WOODS_OUTPUT', Woods.configuration.output_dir)

    puts 'Starting full codebase extraction...'
    puts "Output directory: #{output_dir}"
    puts

    extractor = Woods::Extractor.new(output_dir: output_dir)
    results = woods_with_extraction_lock(output_dir) { extractor.extract_all }

    puts
    puts 'Extraction complete!'
    puts '=' * 50
    results.each do |type, units|
      puts "  #{type.to_s.ljust(15)}: #{units.size} units"
    end
    puts '=' * 50
    puts "  Total: #{results.values.sum(&:size)} units"
    puts
    puts "Output written to: #{output_dir}"
  end

  desc 'Scan the forest — full extraction (alias for extract)'
  task scan: :extract

  desc 'Incremental extraction based on git changes'
  task incremental: :environment do
    require 'woods/extractor'

    output_dir = ENV.fetch('WOODS_OUTPUT', Woods.configuration.output_dir)

    # Determine changed files from CI environment or git
    require 'open3'

    changed_files = if ENV['CHANGED_FILES']
                      # Explicit list from CI
                      ENV['CHANGED_FILES'].split(',').map(&:strip)
                    elsif ENV['CI_COMMIT_BEFORE_SHA']
                      # GitLab CI
                      woods_changed_paths_for_range("#{ENV['CI_COMMIT_BEFORE_SHA']}..#{ENV.fetch('CI_COMMIT_SHA', nil)}")
                    elsif ENV['GITHUB_BASE_REF']
                      # GitHub Actions PR
                      woods_changed_paths_for_range("origin/#{ENV['GITHUB_BASE_REF']}...HEAD")
                    else
                      # Default: changes since last commit
                      woods_changed_paths_for_range('HEAD~1')
                    end

    # Filter to paths that imply extraction work. The rule set lives in
    # PathDispatcher alongside the dispatch itself — a second hand-maintained
    # pattern list here would drift, and a path this filter drops never
    # reaches the index however good the dispatch behind it is (#164).
    dispatcher = Woods::PathDispatcher.new
    changed_files = changed_files.reject(&:empty?).select { |f| dispatcher.relevant?(f) }

    if changed_files.empty?
      puts 'No relevant files changed. Skipping extraction.'
      exit 0
    end

    case woods_daemon_coverage(output_dir)
    when :running
      puts 'A watch daemon is maintaining this index — skipping.'
      puts 'It reconciles anything changed since the last publish when it starts, so these are covered.'
      puts 'Set WOODS_IGNORE_WATCH=1 to extract anyway.'
      exit 0
    when :degraded
      # Alive but unable to update. Standing down here would exit 0 over work
      # nothing is actually doing.
      puts 'Warning: a watch daemon is alive but degraded — extracting anyway rather than assuming coverage.'
    end

    puts "Incremental extraction for #{changed_files.size} changed files..."
    changed_files.each { |f| puts "  - #{f}" }
    puts

    extractor = Woods::Extractor.new(output_dir: output_dir)
    affected = woods_with_extraction_lock(output_dir) { extractor.extract_changed(changed_files) }

    puts
    puts "Re-extracted #{affected.size} affected units."
  end

  desc 'Tend the garden — incremental extraction (alias for incremental)'
  task tend: :incremental

  desc 'Watch the app and keep the index current (resident daemon)'
  task watch: :environment do
    # Both, and the extractor is not optional. The daemon's default
    # extractor_factory names Woods::Extractor lazily, so omitting this require
    # loaded and started cleanly and then NameError'd on the first real cycle —
    # which the failure posture turns into a permanently degraded daemon rather
    # than a crash. Every spec pre-requires the extractor in its own setup, so
    # the suite stayed green over a broken entry point.
    require 'woods/extractor'
    require 'woods/watch/daemon'

    output_dir = ENV.fetch('WOODS_OUTPUT', Woods.configuration.output_dir)

    daemon = Woods::Watch::Daemon.new(
      output_dir: output_dir,
      root: Rails.root,
      debounce: Float(ENV.fetch('WOODS_WATCH_DEBOUNCE', Woods::Watch::Daemon::DEFAULT_DEBOUNCE)),
      full_extraction_threshold: Integer(
        ENV.fetch('WOODS_WATCH_FULL_THRESHOLD', Woods::Watch::Daemon::DEFAULT_FULL_EXTRACTION_THRESHOLD)
      ),
      # The documented fix for a container watching a bind mount, where native
      # FS events do not propagate and the daemon would sit silent. Nothing
      # exposed it before, which made the advice unfollowable.
      force_polling: ENV['WOODS_WATCH_POLL'] == '1', # container autodetect also applies; see Watcher.containerized?
      idle_timeout: ENV.fetch('WOODS_WATCH_IDLE_TIMEOUT', nil) && Float(ENV.fetch('WOODS_WATCH_IDLE_TIMEOUT')),
      catch_up: ENV['WOODS_WATCH_CATCH_UP'] != '0',
      logger: Rails.logger
    )

    # The trap sets a flag and nothing else. `daemon.stop` reaches
    # `Listen::Listener#stop`, which drives a state machine behind mutexes —
    # and taking a mutex in trap context raises ThreadError on some Ruby
    # versions, turning Ctrl-C into a crash instead of a clean shutdown. A tiny
    # supervisor thread does the real work outside trap context.
    stop_requested = Queue.new
    %w[INT TERM].each { |sig| Signal.trap(sig) { stop_requested.push(sig) } }
    Thread.new do
      stop_requested.pop
      daemon.stop
    end

    puts "Watching #{Rails.root} — index at #{output_dir}"
    puts 'Ctrl-C to stop.'
    puts

    reason = daemon.run

    if reason == :restart_required
      # Boot-captured state changed; Rails cannot reload it. Exit non-zero so
      # a supervisor (foreman, systemd, `docker compose` restart policy)
      # brings the process back with the new configuration.
      warn 'Restart required — boot-captured configuration changed. Exiting for a supervisor to restart.'
      exit 75 # EX_TEMPFAIL
    end

    puts 'Watcher stopped.'
  end

  desc 'Keep watch over the woods — resident index daemon (alias for watch)'
  task guard: :watch

  desc 'Report whether a watch daemon is maintaining this index (exit 0 if alive)'
  # Deliberately not `=> :environment`. This reads one small JSON file, and the
  # whole point is that a worktree hook can call it before deciding whether to
  # do real work — paying a full Rails boot to find out would cost more than the
  # sync it is trying to avoid. WOODS_OUTPUT covers the non-default layout;
  # otherwise the conventional path is derived without booting.
  task :watch_status do
    require 'woods/watch/status'
    require 'json'

    output_dir = ENV.fetch('WOODS_OUTPUT') { File.join(Dir.pwd, 'tmp/woods') }
    status = Woods::Watch::Status.new(output_dir: output_dir)

    puts JSON.pretty_generate(status.read)
    # Exit status is the point: a worktree hook can `rake woods:watch_status ||
    # start_daemon` without parsing anything.
    exit(status.alive? ? 0 : 1)
  end

  desc 'Re-run named extractors wholesale, e.g. woods:refresh[routes,middleware]'
  task :refresh, [:extractor] => :environment do |_task, args|
    require 'woods/extractor'

    keys = [args[:extractor], *args.extras].compact.map(&:strip).reject(&:empty?)

    if keys.empty?
      puts 'Usage: rake "woods:refresh[routes]"  (comma-separate for several)'
      puts
      puts 'Whole-app extractors — no per-file entry point, so these are the'
      puts 'ones a targeted refresh is normally for:'
      puts "  #{Woods::Extractor::WHOLE_APP_EXTRACTORS.keys.sort.join(', ')}"
      puts
      puts 'Any extractor key is accepted:'
      puts "  #{Woods::Extractor::EXTRACTORS.keys.sort.join(', ')}"
      exit 1
    end

    output_dir = ENV.fetch('WOODS_OUTPUT', Woods.configuration.output_dir)
    extractor = Woods::Extractor.new(output_dir: output_dir)

    # A refresh is a fourth writer against this index, and it rewrites the whole
    # dependency graph. Two writers loading the persisted graph, mutating
    # divergent copies and writing back means the last one silently discards the
    # other's work — and then bumps the generation, telling readers the
    # clobbered state is fresh. Atomic writes do not help: each write is
    # individually intact, the *set* is not. So it serializes like the others.
    begin
      result = woods_with_extraction_lock(output_dir) { extractor.refresh(*keys) }
    rescue ArgumentError => e
      puts "ERROR: #{e.message}"
      puts "Known extractors: #{Woods::Extractor::EXTRACTORS.keys.sort.join(', ')}"
      exit 1
    end

    puts "Refreshed: #{result[:types].join(', ')}"
    puts "Warning: ignored unknown extractor(s): #{result[:unknown].join(', ')}" if result[:unknown].any?
    puts "#{result[:touched].size} unit(s) written or removed."
  end

  desc 'Extract only Rails/gem framework sources (run when dependencies change)'
  task extract_framework: :environment do
    require 'woods/extractor'

    output_dir = ENV.fetch('WOODS_OUTPUT', Woods.configuration.output_dir)

    puts 'Extracting Rails and gem framework sources...'
    puts "Rails version: #{Rails.version}"
    puts

    # Back-compat alias for `woods:refresh[rails_source]` (#169). The old body
    # hand-wrote unit JSON with a bare File.write — no AtomicFile, no path
    # normalization, no _index.json, no manifest counts, no PipelineLock, no
    # generation bump — so the units it produced were invisible to
    # generation-keyed readers and went stale forever. Routing through
    # Extractor#refresh sends framework sources through the same write
    # pipeline (and the same writer lock) as every other unit type. This runs
    # regardless of `include_framework_sources` — an explicit invocation is
    # the escape hatch the knob deliberately leaves open.
    extractor = Woods::Extractor.new(output_dir: output_dir)
    result = woods_with_extraction_lock(output_dir) { extractor.refresh(:rails_source) }

    puts "Extracted #{result[:touched].size} framework source unit(s)."
    puts "Output: #{Pathname.new(output_dir).join('rails_source')}"
  end

  desc 'Validate extracted index integrity'
  task validate: :environment do
    require 'woods/resilience/index_validator'

    output_dir = Pathname.new(ENV.fetch('WOODS_OUTPUT', Woods.configuration.output_dir))

    unless output_dir.exist?
      puts "ERROR: Index directory does not exist: #{output_dir}"
      exit 1
    end

    manifest_path = woods_payload_dir(output_dir).join('manifest.json')
    unless manifest_path.exist?
      puts 'ERROR: Manifest not found. Run extraction first.'
      exit 1
    end

    manifest = JSON.parse(Woods::AtomicFile.read(manifest_path))

    puts 'Validating index...'
    puts "  Extracted at: #{manifest['extracted_at']}"
    puts "  Git SHA: #{manifest['git_sha']}"
    puts

    # One implementation of the check (B-128): the class the worktree
    # integration spec asserts through is the one this task runs.
    report = Woods::Resilience::IndexValidator.new(index_dir: output_dir.to_s, app_root: Rails.root.to_s).validate
    errors = report.errors
    warnings = report.warnings

    if errors.any?
      puts 'ERRORS:'
      errors.each { |e| puts "  ✗ #{e}" }
    end

    if warnings.any?
      puts 'WARNINGS:'
      warnings.each { |w| puts "  ⚠ #{w}" }
    end

    if errors.empty? && warnings.empty?
      puts '✓ Index is valid.'
    elsif errors.empty?
      puts "\n✓ Index is valid with #{warnings.size} warning(s)."
    else
      puts "\n✗ Index has #{errors.size} error(s)."
      exit 1
    end
  end

  desc 'Vet the data — validate index integrity (alias for validate)'
  task vet: :validate

  desc 'Show index statistics'
  task stats: :environment do
    output_dir = Pathname.new(ENV.fetch('WOODS_OUTPUT', Woods.configuration.output_dir))

    unless output_dir.exist?
      puts 'Index directory does not exist. Run extraction first.'
      exit 1
    end

    payload_dir = woods_payload_dir(output_dir)
    manifest_path = payload_dir.join('manifest.json')
    manifest = manifest_path.exist? ? JSON.parse(Woods::AtomicFile.read(manifest_path)) : {}

    puts 'Woods Index Statistics'
    puts '=' * 50
    puts "  Extracted at:  #{manifest['extracted_at'] || 'unknown'}"
    puts "  Rails version: #{manifest['rails_version'] || 'unknown'}"
    puts "  Ruby version:  #{manifest['ruby_version'] || 'unknown'}"
    puts "  Git SHA:       #{manifest['git_sha'] || 'unknown'}"
    puts "  Git branch:    #{manifest['git_branch'] || 'unknown'}"
    puts

    puts 'Units by Type'
    puts '-' * 50

    total_size = 0
    total_units = 0
    total_chunks = 0

    (manifest['counts'] || {}).each do |type, count|
      type_dir = payload_dir.join(type)
      next unless type_dir.exist?

      type_size = Dir[type_dir.join('*.json')].sum { |f| File.size(f) }
      total_size += type_size
      total_units += count

      # Count chunks from index
      index_path = type_dir.join('_index.json')
      type_chunks = 0
      if index_path.exist?
        index = JSON.parse(Woods::AtomicFile.read(index_path))
        type_chunks = index.sum { |u| u['chunk_count'] || 0 }
        total_chunks += type_chunks
      end

      puts "  #{type.ljust(15)}: #{count.to_s.rjust(4)} units, #{type_chunks.to_s.rjust(4)} chunks, #{(type_size / 1024.0).round(1).to_s.rjust(8)} KB"
    end

    puts '-' * 50
    puts "  #{'Total'.ljust(15)}: #{total_units.to_s.rjust(4)} units, #{total_chunks.to_s.rjust(4)} chunks, #{(total_size / 1024.0).round(1).to_s.rjust(8)} KB"
    puts

    # Dependency graph stats
    graph_path = payload_dir.join('dependency_graph.json')
    if graph_path.exist?
      graph = JSON.parse(Woods::AtomicFile.read(graph_path))
      stats = graph['stats'] || {}
      puts 'Dependency Graph'
      puts '-' * 50
      puts "  Nodes: #{stats['node_count'] || 'unknown'}"
      puts "  Edges: #{stats['edge_count'] || 'unknown'}"
    end
  end

  desc 'Take a look — show index statistics (alias for stats)'
  task look: :stats

  desc 'Clean extracted index'
  task clean: :environment do
    output_dir = Pathname.new(ENV.fetch('WOODS_OUTPUT', Woods.configuration.output_dir))

    if output_dir.exist?
      puts "Removing #{output_dir}..."
      exit 1 unless woods_clean_index(output_dir) == :cleaned
      puts 'Done.'
    else
      puts 'Index directory does not exist.'
    end
  end

  desc 'Clear the brush — remove index (alias for clean)'
  task clear: :clean

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

  # Internal debugging tool — hidden from `rails -T`
  task :retrieve, [:query] => :environment do |_t, args|
    query = args[:query] || raise('Usage: rake woods:retrieve[query]')

    puts woods_run_retrieval(query)
  end

  desc 'Embed all extracted units'
  task embed: :environment do
    require 'woods'
    require 'woods/tasks'

    # Embedding writes dumps/, checkpoint.json and woods.json under the same
    # output dir the extraction writers own — and `woods:clean` deletes them —
    # so it serializes on the same PipelineLock (#170). One lock domain per
    # index, deliberately coarse: an embed does block an extract it doesn't
    # byte-conflict with, but the failure the lock prevents is a concurrent
    # clean/extract silently clobbering a dump mid-promotion, and a second
    # lock name would reintroduce exactly the unlocked-writer gap.
    output_dir = ENV.fetch('WOODS_OUTPUT', Woods.configuration.output_dir)

    indexer = Woods::Tasks.build_embed_indexer
    puts 'Embedding all extracted units...'
    stats = woods_with_extraction_lock(output_dir) { indexer.index_all }
    Woods::Tasks.print_embed_stats(stats, mode: :full)
  end

  desc 'Nest the data — embed all units (alias for embed)'
  task nest: :embed

  desc 'Embed changed units only (incremental)'
  task embed_incremental: :environment do
    require 'woods'
    require 'woods/tasks'

    # Same lock domain as woods:embed — see the comment there (#170).
    output_dir = ENV.fetch('WOODS_OUTPUT', Woods.configuration.output_dir)

    indexer = Woods::Tasks.build_embed_indexer
    puts 'Embedding changed units (incremental)...'
    stats = woods_with_extraction_lock(output_dir) { indexer.index_incremental }
    Woods::Tasks.print_embed_stats(stats, mode: :incremental)
  end

  desc 'Hone the blade — incremental embedding (alias for embed_incremental)'
  task hone: :embed_incremental

  # Internal debugging tool — hidden from `rails -T`
  task :self_analyze do
    require 'digest'
    require 'json'
    require 'fileutils'
    require 'woods/ruby_analyzer'
    require 'woods/dependency_graph'
    require 'woods/graph_analyzer'
    require 'woods/ruby_analyzer/mermaid_renderer'

    gem_root = File.expand_path('../..', __dir__)
    json_dir = File.join(gem_root, 'tmp', 'woods_self')
    docs_dir = File.join(gem_root, 'docs', 'self-analysis')
    manifest_path = File.join(json_dir, 'manifest.json')

    # 1. Check staleness via source_checksum
    lib_files = Dir.glob(File.join(gem_root, 'lib', '**', '*.rb'))
    source_content = lib_files.map { |f| File.read(f) }.join
    source_checksum = Digest::SHA256.hexdigest(source_content)

    if File.exist?(manifest_path)
      existing = JSON.parse(File.read(manifest_path))
      if existing['source_checksum'] == source_checksum
        puts 'Source unchanged — skipping self-analysis.'
        next
      end
    end

    puts 'Running self-analysis on gem source...'

    # 2. Run RubyAnalyzer
    units = Woods::RubyAnalyzer.analyze(paths: [File.join(gem_root, 'lib', 'woods')])
    puts "  Analyzed #{units.size} units"

    # 3. Build DependencyGraph + GraphAnalyzer
    graph = Woods::DependencyGraph.new
    units.each { |unit| graph.register(unit) }
    analyzer = Woods::GraphAnalyzer.new(graph)
    analysis = analyzer.analyze
    graph_data = graph.to_h

    # 4. Write JSON to tmp/woods_self/
    FileUtils.mkdir_p(json_dir)

    units.each do |unit|
      file_name = "#{unit.identifier.gsub(/[^a-zA-Z0-9_]/, '_')}.json"
      File.write(
        File.join(json_dir, file_name),
        JSON.pretty_generate(unit.to_h)
      )
    end

    File.write(
      File.join(json_dir, 'dependency_graph.json'),
      JSON.pretty_generate(graph_data)
    )

    File.write(
      File.join(json_dir, 'analysis.json'),
      JSON.pretty_generate(analysis)
    )

    manifest = {
      'source_checksum' => source_checksum,
      'generated_at' => Time.now.iso8601,
      'unit_count' => units.size,
      'node_count' => graph_data[:stats][:node_count],
      'edge_count' => graph_data[:stats][:edge_count]
    }
    File.write(manifest_path, JSON.pretty_generate(manifest))

    # 5. Render Mermaid to docs/self-analysis/
    FileUtils.mkdir_p(docs_dir)
    renderer = Woods::RubyAnalyzer::MermaidRenderer.new

    File.write(
      File.join(docs_dir, 'architecture.md'),
      renderer.render_architecture(units, graph_data, analysis)
    )

    File.write(
      File.join(docs_dir, 'call-graph.md'),
      "# Call Graph\n\n```mermaid\n#{renderer.render_call_graph(units)}\n```\n"
    )

    File.write(
      File.join(docs_dir, 'dependency-map.md'),
      "# Dependency Map\n\n```mermaid\n#{renderer.render_dependency_map(graph_data)}\n```\n"
    )

    File.write(
      File.join(docs_dir, 'dataflow.md'),
      "# Data Flow\n\n```mermaid\n#{renderer.render_dataflow(units)}\n```\n"
    )

    puts "  JSON output: #{json_dir}"
    puts "  Mermaid docs: #{docs_dir}"
    puts 'Self-analysis complete.'
  end

  desc 'Generate execution flow document for a Rails entry point'
  task :flow, [:entry_point] => :environment do |_t, args|
    require 'json'
    require 'woods/flow_assembler'
    require 'woods/dependency_graph'

    entry_point = args[:entry_point]
    unless entry_point
      puts 'Usage: rake woods:flow[EntryPoint#method]'
      exit 1
    end

    output_dir = ENV.fetch('WOODS_OUTPUT', Woods.configuration.output_dir)
    graph_path = File.join(woods_payload_dir(output_dir).to_s, 'dependency_graph.json')

    unless File.exist?(graph_path)
      puts "ERROR: Dependency graph not found at #{graph_path}"
      puts 'Run woods:extract first.'
      exit 1
    end

    graph_data = JSON.parse(Woods::AtomicFile.read(graph_path))
    graph = Woods::DependencyGraph.from_h(graph_data)

    max_depth = ENV.fetch('MAX_DEPTH', 5).to_i
    assembler = Woods::FlowAssembler.new(graph: graph, extracted_dir: woods_payload_dir(output_dir).to_s)
    flow = assembler.assemble(entry_point, max_depth: max_depth)

    format = ENV.fetch('FORMAT', 'markdown').downcase

    case format
    when 'json'
      puts JSON.pretty_generate(flow.to_h)
    else
      puts flow.to_markdown
    end
  end

  desc 'Start the embedded console MCP server (stdio transport)'
  task :console do
    # Capture stdout before Rails boot to keep MCP protocol clean.
    # Rails boot emits OpenTelemetry, gem warnings, etc. to stdout —
    # MCP client cannot parse these as JSON-RPC.
    # Global variable passes the fd to exe/woods-console via load.
    $woods_protocol_out = $stdout.dup # rubocop:disable Style/GlobalVars
    $stdout.reopen($stderr)

    Rake::Task[:environment].invoke

    load File.expand_path('../../exe/woods-console', __dir__)
  end

  desc 'Sync extraction data to Notion databases (Data Models + Columns)'
  task notion_sync: :environment do
    require 'woods/notion/exporter'

    config = Woods.configuration
    # A non-blank env var takes precedence over the configured value; a blank
    # NOTION_API_TOKEN is treated as absent. Shared resolution keeps the rake
    # task, the exporter, and the MCP tool consistent.
    config.notion_api_token = Woods.resolve_notion_token(config)

    unless config.notion_api_token
      puts 'ERROR: Notion API token not configured.'
      puts 'Set NOTION_API_TOKEN env var or configure notion_api_token in Woods.configure.'
      exit 1
    end

    output_dir = ENV.fetch('WOODS_OUTPUT', config.output_dir)

    db_ids = config.notion_database_ids || {}
    if db_ids.empty?
      puts 'ERROR: No Notion database IDs configured.'
      puts 'Set notion_database_ids in Woods.configure:'
      puts '  config.notion_database_ids = { data_models: "db-uuid", columns: "db-uuid" }'
      exit 1
    end

    puts 'Syncing extraction data to Notion...'
    puts "  Output dir: #{output_dir}"
    puts "  Databases:  #{db_ids.keys.join(', ')}"
    puts

    exporter = Woods::Notion::Exporter.new(index_dir: output_dir)
    stats = exporter.sync_all

    puts 'Sync complete!'
    puts "  Data Models: #{stats[:data_models]} synced"
    puts "  Columns:     #{stats[:columns]} synced"

    if stats[:errors].any?
      puts "  Errors:      #{stats[:errors].size}"
      stats[:errors].first(5).each { |e| puts "    - #{e}" }
      puts "    ... and #{stats[:errors].size - 5} more" if stats[:errors].size > 5
    end
  end

  desc 'Send findings from the field — sync to Notion (alias for notion_sync)'
  task send: :notion_sync

  desc 'Sync extraction data to Unblocked collection (Documents API)'
  task unblocked_sync: :environment do
    require 'woods/unblocked/exporter'

    config = Woods.configuration
    config.unblocked_api_token = ENV.fetch('UNBLOCKED_API_TOKEN', nil) || config.unblocked_api_token
    config.unblocked_collection_id = ENV.fetch('UNBLOCKED_COLLECTION_ID', nil) || config.unblocked_collection_id
    config.unblocked_repo_url = ENV.fetch('UNBLOCKED_REPO_URL', nil) || config.unblocked_repo_url

    unless config.unblocked_api_token
      puts 'ERROR: Unblocked API token not configured.'
      puts 'Set UNBLOCKED_API_TOKEN env var or configure unblocked_api_token in Woods.configure.'
      exit 1
    end

    unless config.unblocked_collection_id
      puts 'ERROR: Unblocked collection ID not configured.'
      puts 'Set UNBLOCKED_COLLECTION_ID env var or configure unblocked_collection_id in Woods.configure.'
      exit 1
    end

    unless config.unblocked_repo_url
      puts 'ERROR: Repository URL not configured.'
      puts 'Set UNBLOCKED_REPO_URL env var or configure unblocked_repo_url in Woods.configure.'
      puts 'Example: https://github.com/your-org/your-repo'
      exit 1
    end

    output_dir = ENV.fetch('WOODS_OUTPUT', config.output_dir)
    # Truthy set, so FLAG=false / FLAG=0 disables rather than silently enabling.
    env_flag = ->(name) { %w[1 true yes].include?(ENV.fetch(name, '').strip.downcase) }
    force_full = env_flag.call('UNBLOCKED_FORCE_FULL_SYNC')
    force_purge = env_flag.call('UNBLOCKED_FORCE_PURGE')

    puts 'Syncing extraction data to Unblocked...'
    puts "  Output dir:     #{output_dir}"
    puts "  Collection:     #{config.unblocked_collection_id}"
    puts "  Repo URL:       #{config.unblocked_repo_url}"
    puts '  Mode:           full re-sync (UNBLOCKED_FORCE_FULL_SYNC set)' if force_full
    puts

    exporter = Woods::Unblocked::Exporter.new(
      index_dir: output_dir,
      force_full: force_full,
      force_purge: force_purge
    )
    stats = exporter.sync_all

    puts
    puts 'Sync complete!'
    puts "  Documents synced:   #{stats[:synced]}"
    puts "  Documents skipped:  #{stats[:skipped]}"
    puts "  Documents deleted:  #{stats[:deleted]}"

    if stats[:errors].any?
      puts "  Errors:             #{stats[:errors].size}"
      stats[:errors].first(5).each { |e| puts "    - #{e}" }
      puts "    ... and #{stats[:errors].size - 5} more" if stats[:errors].size > 5

      # Fail the task so CI notices — a printed-but-green run is invisible in
      # post-merge pipelines (a dead token would otherwise stay green forever).
      # Exception: budget exhaustion *with* partial progress is the expected
      # cold-start shape; it converges on the next run.
      # Matched on the message because errors reach here as strings, not
      # exceptions. `budget exhausted` is the stable part of
      # BudgetExhaustedError's message — spec/unblocked/rate_limiter_spec.rb
      # pins it so this branch cannot be silently broken by a rewording.
      budget_only = stats[:errors].all? { |e| e.include?('budget exhausted') }
      unless budget_only && stats[:synced].positive?
        puts
        puts 'Sync completed with errors — failing so CI surfaces it.'
        exit 1
      end
    end
  end

  desc 'Relay findings to Unblocked (alias for unblocked_sync)'
  task relay: :unblocked_sync

  desc 'Export extraction data to a self-contained Obsidian vault'
  task obsidian: :environment do
    require 'woods/obsidian/vault_exporter'

    config = Woods.configuration
    output_dir = ENV.fetch('WOODS_OUTPUT', config.output_dir)
    vault_path = ENV.fetch('WOODS_OBSIDIAN_VAULT', File.join(output_dir.to_s, 'obsidian_vault'))
    # Truthy set, so FLAG=false / FLAG=0 disables rather than silently enabling.
    env_flag = ->(name) { %w[1 true yes].include?(ENV.fetch(name, '').strip.downcase) }

    puts 'Exporting extraction data to an Obsidian vault...'
    puts "  Output dir: #{output_dir}"
    puts "  Vault:      #{vault_path}"
    puts

    begin
      exporter = Woods::Obsidian::VaultExporter.new(
        index_dir: output_dir,
        vault_path: vault_path,
        include_source: env_flag.call('WOODS_OBSIDIAN_INCLUDE_SOURCE'),
        include_framework: env_flag.call('WOODS_OBSIDIAN_INCLUDE_FRAMEWORK'),
        force_purge: env_flag.call('WOODS_OBSIDIAN_FORCE_PURGE')
      )
      stats = exporter.export_all
    rescue Woods::Obsidian::ExportError => e
      puts "ERROR: #{e.message}"
      exit 1
    end

    puts 'Export complete!'
    puts "  Notes:    #{stats[:exported]}"
    puts "  Indexes:  #{stats[:indexes]}"
    puts "  Swept:    #{stats[:swept]}"
    puts "  Skipped:  #{stats[:skipped]}"
    puts
    puts "Open it in Obsidian: 'Open folder as vault' -> #{vault_path}"

    if stats[:errors].any?
      puts "  Errors:   #{stats[:errors].size}"
      stats[:errors].first(5).each { |e| puts "    - #{e}" }
      puts "    ... and #{stats[:errors].size - 5} more" if stats[:errors].size > 5
      exit 1
    end
  end

  desc 'Render the codebase as an Obsidian vault (alias for obsidian)'
  task vault: :obsidian

  desc 'Generate a random bearer token for woods-mcp-http (WOODS_MCP_HTTP_TOKEN)'
  task :generate_token do
    require 'securerandom'
    token = SecureRandom.hex(32)
    puts token
    warn 'Set WOODS_MCP_HTTP_TOKEN to this value in the environment where woods-mcp-http runs,'
    warn 'and send it as `Authorization: Bearer <token>` from clients.'
  end
end
