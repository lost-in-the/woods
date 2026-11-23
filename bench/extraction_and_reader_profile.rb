# frozen_string_literal: true

# Repeatable component profiling harness for Woods.
#
# Measures wall time (ms) and object allocations across five hot spots:
#   1. Coordination::LockHeartbeat stop latency
#   2. PublishedIndex#edges(via:) and #dependents_of(id, via:) at 10k nodes / 30k edges
#   3. RouteHelperResolver init-only vs first lookup vs 50 lookups across 5 extractors
#   4. Extractors::LibExtractor across 100 lib files
#   5. MCP::IndexReader deep search across 400 canonical hashed unit files (warm & cold)
#
# Usage:
#   bundle exec ruby bench/extraction_and_reader_profile.rb
#   PROFILE_OUT=/tmp/profile.json bundle exec ruby bench/extraction_and_reader_profile.rb

$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))

require 'digest'
require 'fileutils'
require 'json'
require 'logger'
require 'open3'
require 'pathname'
require 'tmpdir'
require 'active_support/core_ext/object/blank'
require 'active_support/core_ext/string/inflections'
require 'woods'
require 'woods/extractor'
require 'woods/coordination/lock_heartbeat'
require 'woods/published_index'
require 'woods/mcp/index_reader'

# Repeatable component benchmark suite for Woods extraction and reader paths.
module WoodsBench
  REPO_ROOT = File.expand_path('..', __dir__)

  # Fixture builders for synthetic graphs, stubbed Rails apps, and unit corpora.
  module Fixtures
    module_function

    def setup_stub_rails(root, route_count: 500)
      routes = Array.new(route_count) do |i|
        Struct.new(:defaults, :verb, :path).new(
          { controller: "items_#{i}", action: 'index' }, 'GET', Struct.new(:spec).new("/items_#{i}")
        )
      end
      named = routes.each_with_index.to_h { |r, i| [:"items_#{i}", r] }
      app = Struct.new(:routes).new(Struct.new(:named_routes).new(named))
      rails_mod = Module.new
      { root: Pathname.new(root), application: app, logger: Logger.new(IO::NULL), version: '8.0.0', autoloaders: [] }
        .each { |name, val| rails_mod.define_singleton_method(name) { val } }
      Object.send(:remove_const, :Rails) if Object.const_defined?(:Rails, false)
      Object.const_set(:Rails, rails_mod)
    end

    def build_synthetic_graph(node_count: 10_000, edges_per_node: 3)
      vias = %w[belongs_to has_many service_call constant_reference link_to include]
      edges = {}
      reverse = Hash.new { |h, k| h[k] = [] }
      node_count.times do |i|
        edges["Unit#{i}"] = Array.new(edges_per_node) do |j|
          target = "Unit#{(i + j + 1) % node_count}"
          reverse[target] << "Unit#{i}"
          { 'target' => target, 'via' => vias[(i + j) % vias.size], 'type' => 'model' }
        end
      end
      { 'edges' => edges, 'reverse' => reverse, 'nodes' => {}, 'variants' => {} }
    end

    def seed_search_index(idx_dir, count)
      models_dir = File.join(idx_dir, 'models')
      FileUtils.mkdir_p(models_dir)
      entries = Array.new(count) { |i| write_model_unit(models_dir, i) }
      File.write(File.join(models_dir, '_index.json'), JSON.generate(entries))
      write_manifest(idx_dir, count)
      empty_graph = { 'nodes' => {}, 'edges' => {}, 'reverse' => {} }
      File.write(File.join(idx_dir, 'dependency_graph.json'), JSON.generate(empty_graph))
      idx_dir
    end

    def write_model_unit(models_dir, index)
      id = "Model#{index}"
      unit = {
        'type' => 'model', 'identifier' => id, 'file_path' => "app/models/model_#{index}.rb",
        'namespace' => 'Models', 'metadata' => { 'table_name' => "model_#{index}s" },
        'source_code' => ("class #{id} < ApplicationRecord\n  has_many :items\nend\n" * 40),
        'dependencies' => [], 'dependents' => []
      }
      filename = "#{id}_#{Digest::SHA256.hexdigest(id)[0, 8]}.json"
      File.write(File.join(models_dir, filename), JSON.generate(unit))
      { 'identifier' => id, 'file_path' => unit['file_path'], 'namespace' => 'Models' }
    end

    def write_manifest(dir, count)
      manifest = { 'woods_version' => Woods::VERSION, 'counts' => { 'models' => count },
                   'extracted_at' => '2026-11-23T00:00:00Z' }
      File.write(File.join(dir, 'manifest.json'), JSON.generate(manifest))
    end
  end

  module_function

  def git_sha!
    sha, err, st = Open3.capture3('git', '-C', REPO_ROOT, 'rev-parse', 'HEAD')
    raise "git rev-parse HEAD failed in #{REPO_ROOT}: #{err.strip}" unless st.success? && !sha.strip.empty?

    sha.strip
  end

  def median(values)
    sorted = values.sort
    mid = sorted.size / 2
    sorted.size.odd? ? sorted[mid] : ((sorted[mid - 1] + sorted[mid]) / 2.0).round(3)
  end

  def measure(runs: 5, &block)
    samples = Array.new(runs) { sample_once(&block) }
    walls = samples.map { |s| s[:wall_ms] }.sort
    allocs = samples.map { |s| s[:allocations] }.sort
    {
      runs: runs, median_wall_ms: median(walls),
      min_wall_ms: walls.first, max_wall_ms: walls.last, median_allocations: median(allocs)
    }
  end

  def sample_once
    GC.start
    alloc_before = GC.stat(:total_allocated_objects)
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    yield
    wall_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000.0).round(3)
    { wall_ms: wall_ms, allocations: GC.stat(:total_allocated_objects) - alloc_before }
  end

  def bench_lock_heartbeat
    lock = Struct.new(:stale_timeout) { def touch; end }.new(600)
    measure(runs: 3) { Woods::Coordination::LockHeartbeat.run(lock) { sleep 0.02 } }
  end

  def bench_edge_shaper(tmpdir)
    graph_dir = File.join(tmpdir, 'edge_shaper_index')
    FileUtils.mkdir_p(graph_dir)
    File.write(File.join(graph_dir, 'dependency_graph.json'), JSON.generate(Fixtures.build_synthetic_graph))
    Fixtures.write_manifest(graph_dir, 10_000)
    index = Woods::PublishedIndex.new(graph_dir)
    index.edges(via: 'belongs_to')
    {
      edges_via: measure(runs: 7) { index.edges(via: 'belongs_to') },
      dependents_via: measure(runs: 7) { index.dependents_of('Unit500', via: 'belongs_to') }
    }
  end

  def bench_route_helper_init(tmpdir)
    Fixtures.setup_stub_rails(tmpdir, route_count: 500)
    extractors = [
      Woods::Extractors::ControllerExtractor, Woods::Extractors::MailerExtractor,
      Woods::Extractors::PhlexExtractor, Woods::Extractors::ViewComponentExtractor,
      Woods::Extractors::ViewTemplateExtractor
    ]
    {
      init_only_0_lookups: measure(runs: 7) { extractors.each(&:new) },
      init_plus_first_lookup: measure(runs: 7) do
        extractors.each { |klass| klass.new.send(:resolve_route_helper, 'items_42_path') }
      end,
      init_plus_50_lookups: measure(runs: 7) do
        extractors.each do |klass|
          inst = klass.new
          50.times { |i| inst.send(:resolve_route_helper, "items_#{i}_path") }
        end
      end
    }
  end

  def bench_lib_extractor(tmpdir)
    lib_root = File.join(tmpdir, 'lib_bench')
    FileUtils.mkdir_p(File.join(lib_root, 'lib', 'billing'))
    Fixtures.setup_stub_rails(lib_root, route_count: 10)
    100.times do |i|
      src = <<~RUBY
        # frozen_string_literal: true
        module Billing
          class Worker#{i}
            DEFAULT_LIMIT = #{i + 1}
            def initialize(client:); @client = client; end
            def call(order); @client.fetch(order.id); end
          end
        end
      RUBY
      File.write(File.join(lib_root, 'lib', 'billing', "worker_#{i}.rb"), src)
    end
    measure(runs: 5) { Woods::Extractors::LibExtractor.new.extract_all }
  end

  def bench_index_reader_search(tmpdir)
    idx_dir = Fixtures.seed_search_index(File.join(tmpdir, 'search_index'), 400)
    warm = Woods::MCP::IndexReader.new(idx_dir)
    preflight = warm.search('NonExistentNeedleXYZ', fields: %w[source_code], limit: 20)
    stop_reason = preflight.dig(:scan, :stop_reason)
    scanned = preflight.dig(:scan, :scanned_units)
    if stop_reason || scanned != 400
      raise "Reader preflight failed: stop_reason=#{stop_reason.inspect}, scanned_units=#{scanned.inspect}"
    end

    {
      warm_cache: measure(runs: 5) { warm.search('NonExistentNeedleXYZ', fields: %w[source_code], limit: 20) },
      cold_cache: measure(runs: 5) do
        Woods::MCP::IndexReader.new(idx_dir).search('NonExistentNeedleXYZ', fields: %w[source_code], limit: 20)
      end
    }
  end
end

if $PROGRAM_NAME == __FILE__
  Dir.mktmpdir('woods_bench') do |tmpdir|
    results = {
      ruby_version: RUBY_VERSION, woods_version: Woods::VERSION, git_sha: WoodsBench.git_sha!,
      benchmarks: {
        lock_heartbeat_stop: WoodsBench.bench_lock_heartbeat,
        edge_shaper: WoodsBench.bench_edge_shaper(tmpdir),
        route_helper_init: WoodsBench.bench_route_helper_init(tmpdir),
        lib_extractor_100_files: WoodsBench.bench_lib_extractor(tmpdir),
        index_reader_deep_search_400_units: WoodsBench.bench_index_reader_search(tmpdir)
      }
    }
    puts JSON.pretty_generate(results)
    out_path = ENV.fetch('PROFILE_OUT', nil)
    File.write(out_path, "#{JSON.pretty_generate(results)}\n") if out_path && !out_path.empty?
  end
end
