# frozen_string_literal: true

# Balanced alternating unprofiled A/B benchmark runner for Woods PRs.
#
# Runs N alternating pairs (AB, BA, AB, BA, ...) across two Woods worktrees
# in fresh Ruby subprocesses with BOTH `WOODS_PROFILE` and `WOODS_PROFILE_OUT`
# explicitly unset, verifying git SHA / clean-tree provenance and fixture
# fingerprints (including exact ordered GraphAnalyzer cycles).
#
# Usage:
#   ruby bench/ab_alternating_compare.rb --base /path/base --cand /path/cand
#   ruby bench/ab_alternating_compare.rb --suite graph --pairs 5 --base ... --cand ... --out receipt.json
#   ruby bench/ab_alternating_compare.rb --suite reader --pairs 5 --base ... --cand ... --markdown

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
          File.write(File.join(mdir, "#{id}.json"), JSON.generate(unit))
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

        warm = Woods::MCP::IndexReader.new(sdir)
        warm.search('NonExistentNeedleXYZ', fields: %w[source_code], limit: 20)
        search_warm = sample { warm.search('NonExistentNeedleXYZ', fields: %w[source_code], limit: 20) }
        search_cold = sample do
          Woods::MCP::IndexReader.new(sdir).search('NonExistentNeedleXYZ', fields: %w[source_code], limit: 20)
        end
        warm_res = search_warm.delete(:result)
        cold_res = search_cold.delete(:result)

        fp = Digest::SHA256.hexdigest(JSON.generate(
          edges_count: edges_res.size, edges_sample: edges_res.first(10),
          deps: deps_res,
          warm_scanned: warm_res.dig(:scan, :scanned_units),
          cold_scanned: cold_res.dig(:scan, :scanned_units)
        ))

        puts JSON.generate(
          metrics: {
            edge_shaper_edges_via_10k: edges_via,
            edge_shaper_deps_via_10k: deps_via,
            index_reader_search_400_warm: search_warm,
            index_reader_search_400_cold: search_cold
          },
          fixture_fingerprints: {
            reader_and_edge_shaper: fp
          }
        )
      end
    RUBY
  end

  # Summary statistics and formatting helpers.
  module Reporter
    module_function

    def summarize(base_runs, cand_runs)
      base_runs.first['metrics'].keys.to_h do |key|
        [key, summarize_metric(base_runs, cand_runs, key)]
      end
    end

    def summarize_metric(base_runs, cand_runs, key)
      base = %w[wall_ms cpu_ms allocations].to_h { |f| [f, extract_series(base_runs, key, f)] }
      cand = %w[wall_ms cpu_ms allocations].to_h { |f| [f, extract_series(cand_runs, key, f)] }
      build_stats(base, cand)
    end

    def extract_series(runs, key, field)
      runs.map { |r| r['metrics'][key][field] }
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
      sorted = values.sort
      sorted[sorted.size / 2]
    end

    def pct(before, after)
      return 'n/a' if before.zero?

      format('%<d>+.1f%%', d: ((after - before).to_f / before) * 100.0)
    end

    def print_report(receipt, markdown: false)
      markdown ? print_markdown(receipt) : print_text(receipt)
      puts "Fixture fingerprints: #{receipt[:fingerprints_match] ? 'PASS' : 'DRIFT'}"
    end

    def print_text(receipt)
      b = receipt[:base]
      c = receipt[:candidate]
      puts "Alternating Unprofiled A/B (#{receipt[:suite]}, #{receipt[:pairs]} pairs, " \
           "#{b[:sha]}[clean=#{b[:clean]}] -> #{c[:sha]}[clean=#{c[:clean]}])"
      puts '-' * 124
      receipt[:summary].each { |k, s| puts format_text_row(k, s) }
      puts '-' * 124
    end

    def format_text_row(key, stats)
      format(
        '%<k>-30s wall %<bw>7.2f->%<cw>7.2f ms (%<wd>7s) | ' \
        'cpu %<bc>7.2f->%<cc>7.2f ms (%<cd>7s) | allocs %<ba>8d->%<ca>8d (%<ad>7s)',
        k: key, bw: stats[:base_wall_med], cw: stats[:cand_wall_med], wd: stats[:wall_delta],
        bc: stats[:base_cpu_med], cc: stats[:cand_cpu_med], cd: stats[:cpu_delta],
        ba: stats[:base_alloc_med], ca: stats[:cand_alloc_med], ad: stats[:alloc_delta]
      )
    end

    def print_markdown(receipt)
      puts "| Workload (`#{receipt[:base][:sha]}` -> `#{receipt[:candidate][:sha]}`) | " \
           'Wall med (ms) | Wall Δ | CPU med (ms) | CPU Δ | Allocs med | Alloc Δ |'
      puts '|---|---:|---:|---:|---:|---:|---:|'
      receipt[:summary].each do |key, stats|
        puts format(
          '| `%<k>s` | %<bw>.2f -> %<cw>.2f | %<wd>s | %<bc>.2f -> %<cc>.2f | %<cd>s | ' \
          '%<ba>d -> %<ca>d | %<ad>s |',
          k: key, bw: stats[:base_wall_med], cw: stats[:cand_wall_med], wd: stats[:wall_delta],
          bc: stats[:base_cpu_med], cc: stats[:cand_cpu_med], cd: stats[:cpu_delta],
          ba: stats[:base_alloc_med], ca: stats[:cand_alloc_med], ad: stats[:alloc_delta]
        )
      end
    end
  end

  module_function

  def run(argv)
    opts = parse_options(argv)
    worker = worker_source(opts[:suite])
    base_runs, cand_runs = execute_pairs(opts[:base], opts[:cand], opts[:pairs], worker)
    receipt = build_receipt(opts, base_runs, cand_runs)
    File.write(opts[:out], "#{JSON.pretty_generate(receipt)}\n") if opts[:out]
    Reporter.print_report(receipt, markdown: opts[:markdown])
    exit 1 unless receipt[:fingerprints_match]
  end

  def parse_options(argv)
    opts = { suite: 'graph', pairs: 5, markdown: false }
    OptionParser.new do |p|
      p.on('--suite NAME', SUITES) { |v| opts[:suite] = v }
      p.on('--pairs N', Integer) { |v| opts[:pairs] = v }
      p.on('--base DIR') { |v| opts[:base] = File.expand_path(v) }
      p.on('--cand DIR') { |v| opts[:cand] = File.expand_path(v) }
      p.on('--out PATH') { |v| opts[:out] = v }
      p.on('--markdown') { opts[:markdown] = true }
    end.parse!(argv)
    raise ArgumentError, 'Provide --base DIR and --cand DIR' unless opts[:base] && opts[:cand]

    opts
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
    # Explicitly clear both profiling variables so runs are strictly unprofiled.
    env = { 'WOODS_PROFILE' => nil, 'WOODS_PROFILE_OUT' => nil }
    out, err, st = Open3.capture3(env, 'bundle', 'exec', 'ruby', '-e', worker, chdir: dir)
    raise "Arm #{dir} failed:\n#{err}" unless st.success?

    JSON.parse(out.lines.last)
  end

  def git_meta(dir)
    sha, = Open3.capture2('git', '-C', dir, 'rev-parse', '--short', 'HEAD')
    status, = Open3.capture2('git', '-C', dir, 'status', '--porcelain')
    { dir: dir, sha: sha.strip, clean: status.strip.empty? }
  end

  def build_receipt(opts, base_runs, cand_runs)
    b_fp = base_runs.first['fixture_fingerprints']
    c_fp = cand_runs.first['fixture_fingerprints']
    {
      schema_version: 1, ruby_version: RUBY_VERSION, suite: opts[:suite], pairs: opts[:pairs],
      unprofiled_env: { WOODS_PROFILE: nil, WOODS_PROFILE_OUT: nil },
      base: git_meta(opts[:base]), candidate: git_meta(opts[:cand]),
      summary: Reporter.summarize(base_runs, cand_runs),
      fingerprints_match: b_fp == c_fp,
      base_fingerprints: b_fp, candidate_fingerprints: c_fp,
      base_runs: base_runs, cand_runs: cand_runs
    }
  end
end

WoodsABCompare.run(ARGV)
