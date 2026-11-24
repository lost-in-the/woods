# frozen_string_literal: true

# Balanced alternating unprofiled A/B benchmark runner for Woods PRs.
#
# Runs N alternating pairs (AB, BA, AB, BA, ...) across two Woods worktrees
# in fresh Ruby subprocesses with BOTH `WOODS_PROFILE` and `WOODS_PROFILE_OUT`
# explicitly unset and each arm isolated to its own Gemfile, verifying full
# Git SHA / clean-tree provenance before & after sampling and comparing
# non-empty fixture fingerprints across every measured run.
#
# Usage:
#   ruby bench/ab_alternating_compare.rb --suite graph --pairs 5 --base /path/base --cand /path/cand
#   ruby bench/ab_alternating_compare.rb --suite reader --pairs 5 --base ... --cand ... --out receipt.json

require 'digest'
require 'json'
require 'open3'
require 'optparse'

# Alternating unprofiled A/B harness for reproducible PR evidence.
module WoodsABCompare
  SUITES = %w[graph reader].freeze

  # Subprocess worker for the GraphAnalyzer suite.
  module GraphWorker
    SOURCE = <<~'RUBY'
      $LOAD_PATH.unshift(File.expand_path('lib', Dir.pwd))
      require 'digest'
      require 'json'
      require 'woods'
      require 'woods/extracted_unit'
      require 'woods/dependency_graph'
      require 'woods/graph_analyzer'

      def cpu_now
        t = Process.times
        t.utime + t.stime
      end

      def sample
        GC.start
        a0 = GC.stat(:total_allocated_objects)
        c0 = cpu_now
        t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        res = yield
        {
          wall_ms: ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000.0).round(3),
          cpu_ms: ((cpu_now - c0) * 1000.0).round(3),
          allocations: GC.stat(:total_allocated_objects) - a0,
          result: res
        }
      end

      rng = Random.new(42)
      graph = Woods::DependencyGraph.new
      names = Array.new(8201) { |i| "Unit#{i}" }
      names.each_with_index do |name, i|
        u = Woods::ExtractedUnit.new(type: i < 50 ? :model : :service, identifier: name, file_path: "app/u_#{i}.rb")
        u.dependencies = Array.new(4) do
          target = rng.rand < 0.3 ? names[rng.rand(50)] : names[rng.rand(8201)]
          { type: :service, target: target, via: :call }
        end
        graph.register(u)
      end

      analyze = sample { Woods::GraphAnalyzer.new(graph).analyze }
      report = analyze.delete(:result)
      cycles = sample { Woods::GraphAnalyzer.new(graph).cycles }
      cycles_list = cycles.delete(:result)
      bridges = sample { Woods::GraphAnalyzer.new(graph).bridges(limit: 10) }
      bridges.delete(:result)

      fp = Digest::SHA256.hexdigest(JSON.generate(
        stats: report[:stats], hubs: report[:hubs].first(10),
        bridges: report[:bridges], cycles: cycles_list,
        cycles_truncated: report[:cycles_truncated]
      ))

      puts JSON.generate(
        metrics: {
          graph_analyzer_analyze: analyze,
          graph_analyzer_cycles: cycles,
          graph_analyzer_bridges: bridges
        },
        fixture_fingerprints: {
          graph_exact_cycles_and_bridges: fp
        }
      )
    RUBY
  end

  # Subprocess worker for the PublishedIndex / IndexReader suite.
  module ReaderWorker
    SOURCE = <<~'RUBY'
      $LOAD_PATH.unshift(File.expand_path('lib', Dir.pwd))
      require 'digest'
      require 'fileutils'
      require 'json'
      require 'tmpdir'
      require 'woods'
      require 'woods/published_index'
      require 'woods/mcp/index_reader'

      def cpu_now
        t = Process.times
        t.utime + t.stime
      end

      def sample
        GC.start
        a0 = GC.stat(:total_allocated_objects)
        c0 = cpu_now
        t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        res = yield
        {
          wall_ms: ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000.0).round(3),
          cpu_ms: ((cpu_now - c0) * 1000.0).round(3),
          allocations: GC.stat(:total_allocated_objects) - a0,
          result: res
        }
      end

      Dir.mktmpdir('woods_reader_ab') do |tmpdir|
        vias = %w[belongs_to has_many service_call constant_reference link_to include]
        edges = {}
        reverse = Hash.new { |h, k| h[k] = [] }
        10_000.times do |i|
          edges["Unit#{i}"] = Array.new(3) do |j|
            target = "Unit#{(i + j + 1) % 10_000}"
            reverse[target] << "Unit#{i}"
            { 'target' => target, 'via' => vias[(i + j) % vias.size], 'type' => 'model' }
          end
        end
        gdir = File.join(tmpdir, 'graph_idx')
        FileUtils.mkdir_p(gdir)
        File.write(File.join(gdir, 'dependency_graph.json'),
                   JSON.generate('edges' => edges, 'reverse' => reverse, 'nodes' => {}, 'variants' => {}))
        File.write(File.join(gdir, 'manifest.json'), JSON.generate('woods_version' => Woods::VERSION, 'counts' => {}))

        sdir = File.join(tmpdir, 'search_idx')
        mdir = File.join(sdir, 'models')
        FileUtils.mkdir_p(mdir)
        entries = Array.new(400) do |i|
          id = "Model#{i}"
          unit = {
            'type' => 'model', 'identifier' => id, 'file_path' => "app/models/model_#{i}.rb",
            'namespace' => 'Models', 'metadata' => { 'table_name' => "model_#{i}s" },
            'source_code' => ("class #{id} < ApplicationRecord\n  has_many :items\nend\n" * 40),
            'dependencies' => [], 'dependents' => []
          }
          filename = "#{id}_#{Digest::SHA256.hexdigest(id)[0, 8]}.json"
          File.write(File.join(mdir, filename), JSON.generate(unit))
          { 'identifier' => id, 'file_path' => unit['file_path'], 'namespace' => 'Models' }
        end
        File.write(File.join(mdir, '_index.json'), JSON.generate(entries))
        File.write(File.join(sdir, 'manifest.json'),
                   JSON.generate('woods_version' => Woods::VERSION, 'counts' => { 'models' => 400 }))
        File.write(File.join(sdir, 'dependency_graph.json'), JSON.generate('nodes' => {}, 'edges' => {}, 'reverse' => {}))

        index = Woods::PublishedIndex.new(gdir)
        index.edges(via: 'belongs_to')
        edges_via = sample { index.edges(via: 'belongs_to') }
        deps_via = sample { index.dependents_of('Unit500', via: 'belongs_to') }
        edges_res = edges_via.delete(:result)
        deps_res = deps_via.delete(:result)
        index.close

        def verify_complete!(res, expected_units, label)
          status = res.dig(:completeness, :status)
          scanned = res.dig(:scan, :scanned_units)
          return if status == 'complete' && scanned == expected_units

          raise "#{label} incomplete: #{res[:completeness].inspect}, scanned=#{scanned.inspect}"
        end

        warm = Woods::MCP::IndexReader.new(sdir)
        verify_complete!(warm.search('NonExistentNeedleXYZ', fields: %w[source_code], limit: 20), 400, 'preflight')
        run_search = lambda do |reader, label|
          res = reader.search('NonExistentNeedleXYZ', fields: %w[source_code], limit: 20)
          verify_complete!(res, 400, label)
          res
        end
        search_warm = sample { run_search.call(warm, 'warm_search') }
        search_cold = sample { run_search.call(Woods::MCP::IndexReader.new(sdir), 'cold_search') }
        warm_res, cold_res = search_warm.delete(:result), search_cold.delete(:result)
        rkeys = ->(res) { Array(res[:results]).map { |r| [r[:identifier], r[:match_field]] } }
        fp = Digest::SHA256.hexdigest(JSON.generate(
          edges: edges_res, deps: deps_res,
          warm_scanned: warm_res.dig(:scan, :scanned_units), warm_completeness: warm_res[:completeness]&.slice(:status, :reason),
          warm_results: rkeys.call(warm_res), cold_scanned: cold_res.dig(:scan, :scanned_units),
          cold_completeness: cold_res[:completeness]&.slice(:status, :reason), cold_results: rkeys.call(cold_res)
        ))

        puts JSON.generate(
          metrics: { edge_shaper_edges_via_10k: edges_via, edge_shaper_deps_via_10k: deps_via,
                     index_reader_search_400_warm: search_warm, index_reader_search_400_cold: search_cold },
          fixture_fingerprints: { reader_and_edge_shaper: fp }
        )
      end
    RUBY
  end

  # Summary statistics, fingerprint validation, and report formatting.
  module Reporter
    module_function

    def summarize(base_runs, cand_runs)
      base_runs.first.fetch('metrics').keys.to_h do |key|
        [key, summarize_metric(base_runs, cand_runs, key)]
      end
    end

    def summarize_metric(base_runs, cand_runs, key)
      base = %w[wall_ms cpu_ms allocations].to_h { |f| [f, extract_series(base_runs, key, f)] }
      cand = %w[wall_ms cpu_ms allocations].to_h { |f| [f, extract_series(cand_runs, key, f)] }
      build_stats(base, cand)
    end

    def extract_series(runs, key, field)
      runs.map do |run|
        metrics = run.fetch('metrics')
        entry = metrics.fetch(key)
        raise KeyError, "Missing metric #{key}.#{field}" unless entry.key?(field) && !entry[field].nil?

        entry[field]
      end
    end

    def build_stats(base, cand)
      bm_w = median(base['wall_ms'])
      cm_w = median(cand['wall_ms'])
      bm_c = median(base['cpu_ms'])
      cm_c = median(cand['cpu_ms'])
      bm_a = median(base['allocations'])
      cm_a = median(cand['allocations'])
      {
        base_wall_med: bm_w, cand_wall_med: cm_w, wall_delta: pct(bm_w, cm_w),
        base_wall_range: base['wall_ms'].minmax, cand_wall_range: cand['wall_ms'].minmax,
        base_cpu_med: bm_c, cand_cpu_med: cm_c, cpu_delta: pct(bm_c, cm_c),
        base_alloc_med: bm_a, cand_alloc_med: cm_a, alloc_delta: pct(bm_a, cm_a)
      }
    end

    def median(values)
      raise ArgumentError, 'Cannot compute median of empty sample list' if values.empty?

      sorted = values.sort
      mid = sorted.size / 2
      return sorted[mid] if sorted.size.odd?

      ((sorted[mid - 1] + sorted[mid]) / 2.0).round(3)
    end

    def format_alloc(val)
      val.is_a?(Float) && val != val.to_i ? format('%<v>.1f', v: val) : val.to_i.to_s
    end

    def pct(before, after)
      return 'n/a' if before.zero?

      format('%<d>+.1f%%', d: ((after - before).to_f / before) * 100.0)
    end

    def verify_complete_search!(res, expected_units:, label: 'search')
      status = res.dig(:completeness, :status)
      reason = res.dig(:completeness, :reason)
      scanned = res.dig(:scan, :scanned_units)
      return if status == 'complete' && (expected_units.nil? || scanned == expected_units)

      raise "#{label} incomplete: status=#{status.inspect}, reason=#{reason.inspect}, scanned=#{scanned.inspect}"
    end

    def verify_fingerprints(base_runs, cand_runs)
      expected = valid_fingerprints(base_runs.first)
      return ['base pair 1: missing or empty fixture_fingerprints'] unless expected

      mismatches = []
      check_arm_fingerprints('base', base_runs, expected, mismatches)
      check_arm_fingerprints('candidate', cand_runs, expected, mismatches)
      mismatches
    end

    def valid_fingerprints(run)
      fp = run['fixture_fingerprints']
      fp.is_a?(Hash) && !fp.empty? ? fp : nil
    end

    def check_arm_fingerprints(arm, runs, expected, mismatches)
      runs.each_with_index do |run, idx|
        fp = valid_fingerprints(run)
        if fp.nil?
          mismatches << "#{arm} pair #{idx + 1}: missing or empty fixture_fingerprints"
        elsif fp != expected
          diff = (expected.keys | fp.keys).reject { |k| expected[k] == fp[k] }
          mismatches << "#{arm} pair #{idx + 1}: drift in #{diff.join(', ')}"
        end
      end
    end

    def print_report(receipt, markdown: false)
      Printer.print_report(receipt, markdown: markdown)
    end
  end

  # Text and Markdown table rendering for alternating A/B receipts.
  module Printer
    module_function

    def print_report(receipt, markdown: false)
      markdown ? print_markdown(receipt) : print_text(receipt)
      if receipt[:fingerprints_match]
        puts "Fixture fingerprints: PASS (all #{receipt[:pairs]} pairs matched)"
      else
        puts "Fixture fingerprints: DRIFT (#{receipt[:fingerprint_mismatches].join('; ')})"
      end
    end

    def print_text(receipt)
      b = receipt[:base]
      c = receipt[:candidate]
      puts "Alternating Unprofiled A/B (#{receipt[:suite]}, #{receipt[:pairs]} pairs, " \
           "#{b[:sha][0, 12]}[clean=#{b[:clean]}] -> #{c[:sha][0, 12]}[clean=#{c[:clean]}])"
      puts '-' * 124
      receipt[:summary].each { |k, s| puts format_text_row(k, s) }
      puts '-' * 124
    end

    def format_text_row(key, stats)
      format(
        '%<k>-30s wall %<bw>7.2f->%<cw>7.2f ms (%<wd>7s) | ' \
        'cpu %<bc>7.2f->%<cc>7.2f ms (%<cd>7s) | allocs %<ba>9s->%<ca>9s (%<ad>7s)',
        k: key, bw: stats[:base_wall_med], cw: stats[:cand_wall_med], wd: stats[:wall_delta],
        bc: stats[:base_cpu_med], cc: stats[:cand_cpu_med], cd: stats[:cpu_delta],
        ba: Reporter.format_alloc(stats[:base_alloc_med]), ca: Reporter.format_alloc(stats[:cand_alloc_med]),
        ad: stats[:alloc_delta]
      )
    end

    def print_markdown(receipt)
      puts "| Workload (`#{receipt[:base][:sha][0, 12]}` -> `#{receipt[:candidate][:sha][0, 12]}`) | " \
           'Wall med (ms) | Wall Δ | CPU med (ms) | CPU Δ | Allocs med | Alloc Δ |'
      puts '|---|---:|---:|---:|---:|---:|---:|'
      receipt[:summary].each do |key, stats|
        puts format(
          '| `%<k>s` | %<bw>.2f -> %<cw>.2f | %<wd>s | %<bc>.2f -> %<cc>.2f | %<cd>s | ' \
          '%<ba>s -> %<ca>s | %<ad>s |',
          k: key, bw: stats[:base_wall_med], cw: stats[:cand_wall_med], wd: stats[:wall_delta],
          bc: stats[:base_cpu_med], cc: stats[:cand_cpu_med], cd: stats[:cpu_delta],
          ba: Reporter.format_alloc(stats[:base_alloc_med]), ca: Reporter.format_alloc(stats[:cand_alloc_med]),
          ad: stats[:alloc_delta]
        )
      end
    end
  end

  module_function

  def run(argv)
    opts = parse_options(argv)
    base_meta, cand_meta, base_runs, cand_runs = measure_verified(opts)
    receipt = build_receipt(opts, base_meta, cand_meta, base_runs, cand_runs)
    File.write(opts[:out], "#{JSON.pretty_generate(receipt)}\n") if opts[:out]
    Printer.print_report(receipt, markdown: opts[:markdown])
    exit 1 unless receipt[:fingerprints_match]
  end

  def measure_verified(opts)
    base_before = Provenance.verify_worktree!(opts[:base], allow_dirty: opts[:allow_dirty])
    cand_before = Provenance.verify_worktree!(opts[:cand], allow_dirty: opts[:allow_dirty])
    base_runs, cand_runs = execute_pairs(opts[:base], opts[:cand], opts[:pairs], worker_source(opts[:suite]))
    Provenance.verify_unchanged!(base_before, Provenance.git_meta!(opts[:base]))
    Provenance.verify_unchanged!(cand_before, Provenance.git_meta!(opts[:cand]))
    [base_before, cand_before, base_runs, cand_runs]
  end

  def parse_options(argv)
    opts = { suite: 'graph', pairs: 5, markdown: false, allow_dirty: false }
    option_parser(opts).parse!(argv)
    validate_options!(opts)
    opts
  end

  def option_parser(opts)
    OptionParser.new do |p|
      p.on('--suite NAME', SUITES) { |v| opts[:suite] = v }
      p.on('--pairs N', Integer) { |v| opts[:pairs] = v }
      p.on('--base DIR') { |v| opts[:base] = File.expand_path(v) }
      p.on('--cand DIR') { |v| opts[:cand] = File.expand_path(v) }
      p.on('--out PATH') { |v| opts[:out] = v }
      p.on('--markdown') { opts[:markdown] = true }
      p.on('--allow-dirty') { opts[:allow_dirty] = true }
    end
  end

  def validate_options!(opts)
    raise ArgumentError, 'Provide --base DIR and --cand DIR' unless opts[:base] && opts[:cand]
    raise ArgumentError, "--pairs must be >= 1 (got #{opts[:pairs]})" if opts[:pairs] < 1
  end

  def worker_source(suite)
    case suite
    when 'graph' then GraphWorker::SOURCE
    when 'reader' then ReaderWorker::SOURCE
    else raise ArgumentError, "Unsupported suite for standalone runner: #{suite} (use graph or reader)"
    end
  end

  def execute_pairs(base_dir, cand_dir, pairs, worker)
    base_runs = []
    cand_runs = []
    pairs.times do |i|
      warn "[AB] Pair #{i + 1}/#{pairs}..."
      if i.even?
        base_runs << run_arm(base_dir, worker)
        cand_runs << run_arm(cand_dir, worker)
      else
        cand_runs << run_arm(cand_dir, worker)
        base_runs << run_arm(base_dir, worker)
      end
    end
    [base_runs, cand_runs]
  end

  def run_arm(dir, worker)
    # Isolate Bundler to each arm's own Gemfile and explicitly clear both profiling vars.
    env = { 'BUNDLE_GEMFILE' => File.join(dir, 'Gemfile'), 'WOODS_PROFILE' => nil, 'WOODS_PROFILE_OUT' => nil }
    out, err, st = with_clean_bundler_env do
      Open3.capture3(env, 'bundle', 'exec', 'ruby', '-e', worker, chdir: dir)
    end
    raise "Arm #{dir} failed:\n#{err}" unless st.success?

    JSON.parse(out.lines.last)
  end

  def with_clean_bundler_env(&block)
    return Bundler.with_unbundled_env(&block) if defined?(Bundler) && Bundler.respond_to?(:with_unbundled_env)

    yield
  end

  # Git provenance verification before and after arm sampling.
  module Provenance
    CLEAN_GIT_ENV = {
      'GIT_DIR' => nil, 'GIT_WORK_TREE' => nil, 'GIT_INDEX_FILE' => nil,
      'GIT_OBJECT_DIRECTORY' => nil, 'GIT_ALTERNATE_OBJECT_DIRECTORIES' => nil, 'GIT_COMMON_DIR' => nil
    }.freeze

    module_function

    def verify_worktree!(dir, allow_dirty:)
      meta = git_meta!(dir)
      raise "Worktree #{dir} has uncommitted changes (pass --allow-dirty to override)" if !meta[:clean] && !allow_dirty

      meta
    end

    def verify_unchanged!(before_meta, after_meta)
      return if before_meta == after_meta

      raise "Worktree #{before_meta[:dir]} changed during sampling " \
            "(#{before_meta[:sha]}[clean=#{before_meta[:clean]}] -> " \
            "#{after_meta[:sha]}[clean=#{after_meta[:clean]}])"
    end

    def git_meta!(dir)
      sha, sha_err, sha_st = Open3.capture3(CLEAN_GIT_ENV, 'git', '-C', dir, 'rev-parse', 'HEAD')
      raise "git rev-parse HEAD failed for #{dir}: #{sha_err.strip}" unless sha_st.success? && !sha.strip.empty?

      status, st_err, st_ok = Open3.capture3(CLEAN_GIT_ENV, 'git', '-C', dir, 'status', '--porcelain')
      raise "git status failed for #{dir}: #{st_err.strip}" unless st_ok.success?

      clean = status.strip.empty?
      meta = { dir: dir, sha: sha.strip, clean: clean }
      meta[:dirty_digest] = working_tree_digest!(dir, status) unless clean
      meta
    end

    def working_tree_digest!(dir, status)
      diff = git_stdout!(dir, 'diff', 'HEAD')
      untracked = git_stdout!(dir, 'ls-files', '--others', '--exclude-standard', '-z').split("\0").sort
      digest = Digest::SHA256.new
      digest << status << "\0" << diff << "\0"
      untracked.each { |rel| hash_untracked_file(digest, dir, rel) }
      digest.hexdigest
    end

    def hash_untracked_file(digest, dir, rel)
      path = File.join(dir, rel)
      digest << rel << "\0" << (File.file?(path) ? File.binread(path) : '') << "\0"
    end

    def git_stdout!(dir, *args)
      out, err, st = Open3.capture3(CLEAN_GIT_ENV, 'git', '-C', dir, *args)
      raise "git #{args.first} failed for #{dir}: #{err.strip}" unless st.success?

      out
    end
  end

  def verify_unchanged!(before_meta, after_meta)
    Provenance.verify_unchanged!(before_meta, after_meta)
  end

  def build_receipt(opts, base_meta, cand_meta, base_runs, cand_runs)
    mismatches = Reporter.verify_fingerprints(base_runs, cand_runs)
    {
      schema_version: 2, ruby_version: RUBY_VERSION, suite: opts[:suite], pairs: opts[:pairs],
      unprofiled_env: { WOODS_PROFILE: nil, WOODS_PROFILE_OUT: nil },
      base: base_meta, candidate: cand_meta,
      summary: Reporter.summarize(base_runs, cand_runs),
      fingerprints_match: mismatches.empty?,
      fingerprint_mismatches: mismatches,
      expected_fingerprints: base_runs.first['fixture_fingerprints'],
      base_runs: base_runs, cand_runs: cand_runs
    }
  end
end

WoodsABCompare.run(ARGV) if $PROGRAM_NAME == __FILE__
