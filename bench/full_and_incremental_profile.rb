# frozen_string_literal: true

# End-to-end local profiling harness for Woods.
#
# Exercises the real Woods extraction, incremental update, graph analysis,
# request-flow assembly, and MCP index/lexical reader pipelines on deterministic
# synthetic corpora, capturing wall_ms, cpu_ms, object allocations, GC counts,
# and a structural equivalence digest so optimizations can be verified locally
# against a baseline receipt via `script/profile-compare`.
#
# Usage:
#   bundle exec ruby bench/full_and_incremental_profile.rb
#   PROFILE_OUT=/tmp/baseline.json bundle exec ruby bench/full_and_incremental_profile.rb
#   SCALE=2 PROFILE_OUT=/tmp/large.json bundle exec ruby bench/full_and_incremental_profile.rb

$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))

require 'digest'
require 'fileutils'
require 'json'
require 'logger'
require 'open3'
require 'pathname'
require 'tmpdir'
require 'active_support'
require 'active_support/core_ext/object/blank'
require 'active_support/core_ext/string/inflections'
require 'active_support/core_ext/numeric/time'
require 'woods'
require 'woods/extractor'
require 'woods/graph_analyzer'
require 'woods/flow_precomputer'
require 'woods/published_index'
require 'woods/mcp/index_reader'
require 'woods/retrieval/lexical_index'

# Deterministic end-to-end profiling harness for Woods.
module WoodsEndToEndProfile
  # Synthetic Rails-shaped application generator for reproducible extraction runs.
  module AppFixture
    DIRS = %w[
      app/services app/jobs app/policies app/serializers app/concerns
      app/decorators app/forms app/views/orders app/views/shared
      lib/billing lib/tasks config/locales
    ].freeze

    module_function

    def build(root, scale: 1)
      DIRS.each { |rel| FileUtils.mkdir_p(File.join(root, rel)) }
      write_concerns(root, 15 * scale)
      write_services(root, 60 * scale, 15 * scale)
      write_jobs(root, 30 * scale, 60 * scale)
      write_policies_and_serializers(root, 25 * scale)
      write_libs(root, 50 * scale)
      write_views_and_locales(root, 25 * scale)
    end

    def write_concerns(root, count)
      count.times { |i| write(root, "app/concerns/trackable_#{i}.rb", Templates.concern(i)) }
    end

    def write_services(root, count, concern_count)
      count.times do |i|
        write(root, "app/services/billing/processor_#{i}_service.rb", Templates.service(i, count, concern_count))
      end
    end

    def write_jobs(root, count, service_count)
      count.times { |i| write(root, "app/jobs/dispatch_#{i}_job.rb", Templates.job(i, service_count)) }
    end

    def write_policies_and_serializers(root, count)
      count.times do |i|
        write(root, "app/policies/record_#{i}_policy.rb", Templates.policy(i))
        write(root, "app/serializers/record_#{i}_serializer.rb", Templates.serializer(i))
      end
    end

    def write_libs(root, count)
      count.times { |i| write(root, "lib/billing/worker_#{i}.rb", Templates.worker(i, count)) }
    end

    def write_views_and_locales(root, count)
      write(root, 'app/views/shared/_badge.html.erb', '<span class="badge"><%= label %></span>')
      count.times { |i| write(root, "app/views/orders/view_#{i}.html.erb", Templates.view(i)) }
      write(root, 'config/locales/en.yml', "en:\n  orders:\n    title: Orders\n    empty: None\n")
      write(root, 'lib/tasks/billing.rake', Templates.rake)
    end

    def write(root, rel, content)
      path = File.join(root, rel)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, content)
    end
  end

  # Source templates for synthetic Rails-shaped fixture files.
  module Templates
    module_function

    def concern(index)
      <<~RUBY
        # frozen_string_literal: true
        module Trackable#{index}
          extend ActiveSupport::Concern
          included do
            def tracked_key_#{index}; "track_#{index}"; end
          end
        end
      RUBY
    end

    def service(index, count, concern_count)
      <<~RUBY
        # frozen_string_literal: true
        module Billing
          class Processor#{index}Service
            include Trackable#{index % concern_count}
            LIMIT = #{index + 10}
            def initialize(account:, gateway: nil)
              @account = account
              @gateway = gateway
            end
            def call(order)
              return nil unless order
              Billing::Worker#{index % [count / 2, 1].max}.new(client: @gateway).call(order)
              Billing::Processor#{(index + 1) % count}Service.new(account: @account) if order.id > LIMIT
            end
          end
        end
      RUBY
    end

    def job(index, service_count)
      <<~RUBY
        # frozen_string_literal: true
        class Dispatch#{index}Job < ApplicationJob
          queue_as :default
          def perform(order_id)
            Billing::Processor#{index % service_count}Service.new(account: order_id).call(nil)
          end
        end
      RUBY
    end

    def policy(index)
      <<~RUBY
        # frozen_string_literal: true
        class Record#{index}Policy
          def show?; true; end
          def update?; false; end
        end
      RUBY
    end

    def serializer(index)
      <<~RUBY
        # frozen_string_literal: true
        class Record#{index}Serializer
          attributes :id, :name, :status
        end
      RUBY
    end

    def worker(index, count)
      <<~RUBY
        # frozen_string_literal: true
        module Billing
          class Worker#{index}
            DEFAULT_RETRIES = #{(index % 5) + 1}
            def initialize(client:, logger: nil)
              @client = client
              @logger = logger
            end
            def call(order)
              payload = @client.fetch(order.id)
              return nil unless payload
              Billing::Worker#{(index + 1) % count}.new(client: @client) if DEFAULT_RETRIES > 3
              payload
            end
          end
        end
      RUBY
    end

    def view(index)
      <<~ERB
        <div class="order-<%= @order_#{index} %>">
          <%= render partial: "shared/badge", locals: { label: "Order #{index}" } %>
          <%= link_to "View", items_#{index}_path %>
        </div>
      ERB
    end

    def rake
      "namespace :billing do\n  task :sync do\n    Billing::Worker0.new(client: nil)\n  end\nend\n"
    end
  end

  # Minimal in-process Rails and ActiveRecord stubs for boot-free extraction profiling.
  module RailsStub
    module_function

    def install(root, route_count: 250)
      rails_mod = build_rails_module(root, build_app(route_count))
      Object.send(:remove_const, :Rails) if Object.const_defined?(:Rails, false)
      Object.const_set(:Rails, rails_mod)
      install_active_record_stub
    end

    def build_app(route_count)
      routes = Array.new(route_count) do |i|
        Struct.new(:defaults, :verb, :path).new(
          { controller: "items_#{i}", action: 'index' }, 'GET', Struct.new(:spec).new("/items_#{i}")
        )
      end
      named = routes.each_with_index.to_h { |r, i| [:"items_#{i}", r] }
      route_set = Struct.new(:named_routes, :routes).new(named, [])
      cfg = Struct.new(:autoload_paths, :eager_load_paths, :middleware).new([], [], [])
      Struct.new(:routes, :config) { def eager_load!; end }.new(route_set, cfg)
    end

    def build_rails_module(root, app)
      autoloaders = Struct.new(:main) { def each; end }.new(nil)
      rails_mod = Module.new
      {
        root: Pathname.new(root), application: app, logger: Logger.new(IO::NULL),
        version: '8.0.0', autoloaders: autoloaders, env: ActiveSupport::StringInquirer.new('test')
      }.each { |name, val| rails_mod.define_singleton_method(name) { val } }
      rails_mod
    end

    def install_active_record_stub
      return if defined?(ActiveRecord::Base)

      ar = Module.new
      ar.const_set(:Base, Class.new { def self.descendants = [] })
      Object.const_set(:ActiveRecord, ar)
    end
  end

  # Median sampler for wall time, CPU time, allocations, and GC counts.
  module Sampler
    module_function

    def measure(runs: 3, &block)
      samples = Array.new(runs) { sample_once(&block) }
      summarize(samples, runs)
    end

    def sample_once
      GC.start
      a0 = GC.stat(:total_allocated_objects)
      g0 = GC.stat(:count)
      c0 = cpu_now
      t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      val = yield
      {
        wall_ms: ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000.0).round(3),
        cpu_ms: ((cpu_now - c0) * 1000.0).round(3),
        allocations: GC.stat(:total_allocated_objects) - a0,
        gc_count: GC.stat(:count) - g0,
        result: val
      }
    end

    def summarize(samples, runs)
      {
        runs: runs,
        median_wall_ms: median(samples.map { |s| s[:wall_ms] }),
        median_cpu_ms: median(samples.map { |s| s[:cpu_ms] }),
        median_allocations: median(samples.map { |s| s[:allocations] }),
        median_gc_count: median(samples.map { |s| s[:gc_count] }),
        last_result: samples.last[:result]
      }
    end

    def median(values)
      sorted = values.sort
      mid = sorted.size / 2
      sorted.size.odd? ? sorted[mid] : ((sorted[mid - 1] + sorted[mid]) / 2.0).round(3)
    end

    def cpu_now
      t = Process.times
      t.utime + t.stime
    end
  end

  # Synthetic graph analysis and flow precomputation workloads.
  module GraphAndFlowBench
    module_function

    def bench_graph_analyzer(node_count: 8201, hubs: 50)
      graph = build_synthetic_graph(node_count: node_count, hubs: hubs)
      analyze = Sampler.measure(runs: 3) { Woods::GraphAnalyzer.new(graph).analyze }
      cycles = Sampler.measure(runs: 3) { Woods::GraphAnalyzer.new(graph).cycles }
      bridges = Sampler.measure(runs: 3) { Woods::GraphAnalyzer.new(graph).bridges(limit: 10) }
      report = analyze.delete(:last_result)
      cycles.delete(:last_result)
      bridges.delete(:last_result)
      { analyze: analyze, cycles: cycles, bridges: bridges, digest: graph_digest(report) }
    end

    def build_synthetic_graph(node_count:, hubs:)
      rng = Random.new(42)
      graph = Woods::DependencyGraph.new
      names = Array.new(node_count) { |i| "Unit#{i}" }
      names.each_with_index do |name, i|
        unit = Woods::ExtractedUnit.new(
          type: i < hubs ? :model : :service, identifier: name, file_path: "app/u_#{i}.rb"
        )
        unit.dependencies = Array.new(4) do
          target = rng.rand < 0.3 ? names[rng.rand(hubs)] : names[rng.rand(node_count)]
          { type: :service, target: target, via: :call }
        end
        graph.register(unit)
      end
      graph
    end

    def graph_digest(report)
      Digest::SHA256.hexdigest(JSON.generate(
                                 stats: report[:stats], hubs: report[:hubs].first(10),
                                 bridges: report[:bridges], cycles: report[:cycles],
                                 cycles_truncated: report[:cycles_truncated]
                               ))
    end

    def bench_flow_precomputer(tmpdir, controllers: 60, actions: 6, services: 300)
      dir = File.join(tmpdir, 'flow_index')
      %w[controllers services flows].each { |sub| FileUtils.mkdir_p(File.join(dir, sub)) }
      graph, ctrl_units = seed_flow_corpus(dir, controllers: controllers, actions: actions, services: services)
      pre = Sampler.measure(runs: 3) { Woods::FlowPrecomputer.new(units: ctrl_units, graph: graph, output_dir: dir).precompute }
      delta = Sampler.measure(runs: 3) do
        Woods::FlowPrecomputer.new(units: [], graph: graph, output_dir: dir)
                              .recompute_delta(touched_units: ctrl_units.first(10), removed_identifiers: [])
      end
      pre_res = pre.delete(:last_result)
      delta_res = delta.delete(:last_result)
      delta_digest = fingerprint_flow_delta(dir, ctrl_units.first(10), delta_res)
      {
        precompute: pre, recompute_delta: delta,
        digest: Digest::SHA256.hexdigest(JSON.generate(pre_res)),
        delta_digest: delta_digest
      }
    end

    def fingerprint_flow_delta(dir, touched_units, delta_res)
      flow_index = JSON.parse(File.read(File.join(dir, 'flows', 'flow_index.json')))
      touched_ids = touched_units.map(&:identifier)
      touched_files = flow_index.select { |entry, _| touched_ids.any? { |id| entry.start_with?("#{id}#") } }
                                .sort.to_h { |entry, rel| [entry, normalized_flow_doc(File.join(dir, rel))] }
      Digest::SHA256.hexdigest(JSON.generate(delta: delta_res, flow_index: flow_index.sort.to_h, files: touched_files))
    end

    def normalized_flow_doc(path)
      doc = JSON.parse(File.read(path))
      doc['generated_at'] = '<ts>' if doc.is_a?(Hash) && doc.key?('generated_at')
      doc
    end

    def seed_flow_corpus(dir, controllers:, actions:, services:)
      rng = Random.new(99)
      graph = Woods::DependencyGraph.new
      seed_flow_services(dir, graph, services, rng)
      ctrl_units = seed_flow_controllers(dir, graph, { count: controllers, actions: actions, services: services }, rng)
      File.write(File.join(dir, 'dependency_graph.json'), JSON.generate(graph.to_h))
      [graph, ctrl_units]
    end

    def seed_flow_services(dir, graph, services, rng)
      filler = (1..15).map { |k| "  def helper_#{k}(x); x + #{k}; end" }.join("\n")
      services.times do |i|
        name = "Service#{i}"
        next_s = i + 1 < services && rng.rand < 0.5 ? "Service#{i + 1}" : nil
        body = next_s ? "  def call(a)\n    #{next_s}.new.call(a)\n  end" : '  def call(a); a; end'
        unit = Woods::ExtractedUnit.new(type: :service, identifier: name, file_path: "app/services/service_#{i}.rb")
        unit.source_code = "class #{name}\n#{body}\n#{filler}\nend\n"
        unit.dependencies = next_s ? [{ type: :service, target: next_s, via: :call }] : []
        graph.register(unit)
        File.write(File.join(dir, 'services', "#{name}.json"), JSON.generate(unit.to_h))
      end
    end

    def seed_flow_controllers(dir, graph, opts, rng)
      Array.new(opts[:count]) do |i|
        name = "Ctrl#{i}Controller"
        defs = Array.new(opts[:actions]) do |a|
          "  def act_#{a}\n    Service#{rng.rand(opts[:services])}.new.call(params)\n  end"
        end
        unit = Woods::ExtractedUnit.new(type: :controller, identifier: name, file_path: "app/controllers/ctrl_#{i}.rb")
        unit.source_code = "class #{name} < ApplicationController\n#{defs.join("\n")}\nend\n"
        unit.metadata = { actions: Array.new(opts[:actions]) { |a| "act_#{a}" } }
        graph.register(unit)
        File.write(File.join(dir, 'controllers', "#{name}.json"), JSON.generate(unit.to_h))
        unit
      end
    end
  end

  # PublishedIndex, IndexReader, and LexicalIndex workloads.
  module ReaderBench
    module_function

    def run(index_dir)
      index = Woods::PublishedIndex.new(index_dir)
      reader = Woods::MCP::IndexReader.new(index_dir)
      warmup(index, reader)
      metrics = collect_metrics(index, reader)
      index.close
      metrics
    end

    def warmup(index, reader)
      index.edges(via: 'include')
      reader.search('NonExistentNeedleXYZ', fields: %w[source_code], limit: 20)
    end

    def collect_metrics(index, reader)
      edges_via = Sampler.measure(runs: 5) { index.edges(via: 'include') }
      deps_via = Sampler.measure(runs: 5) { index.dependents_of('Trackable0', via: 'include') }
      deep = Sampler.measure(runs: 5) { reader.search('NonExistentNeedleXYZ', fields: %w[source_code], limit: 20) }
      lex_build, lex_query = measure_lexical(reader)
      digest = build_digest(edges_via, deps_via, deep, lex_query)
      {
        edges_via: edges_via, dependents_via: deps_via, deep_search: deep,
        lexical_build: lex_build, lexical_query: lex_query, digest: digest
      }
    end

    def measure_lexical(reader)
      units_map = build_lexical_units(reader)
      lex_build = Sampler.measure(runs: 3) { Woods::Retrieval::LexicalIndex.new(units: units_map) }
      built_lex = lex_build.delete(:last_result)
      lex_query = Sampler.measure(runs: 5) do
        built_lex.execute(query: 'billing processor worker gateway order', limit: 20)
      end
      [lex_build, lex_query]
    end

    def build_digest(edges_via, deps_via, deep, lex_query)
      edges_res = edges_via.delete(:last_result)
      deps_res = deps_via.delete(:last_result)
      search_res = deep.delete(:last_result)
      verify_complete_search!(search_res)
      lex_res = lex_query.delete(:last_result)
      lex_top = lex_res.candidates.first(5).map { |c| [c.identifier, c.score.round(6)] }
      Digest::SHA256.hexdigest(JSON.generate(
                                 edges: edges_res, dependents: deps_res,
                                 scanned_units: search_res.dig(:scan, :scanned_units),
                                 search_completeness: search_res[:completeness]&.slice(:status, :reason),
                                 lex_top: lex_top
                               ))
    end

    def verify_complete_search!(res)
      status = res.dig(:completeness, :status)
      reason = res.dig(:completeness, :reason)
      scanned = res.dig(:scan, :scanned_units)
      return if status == 'complete' && scanned.is_a?(Integer) && scanned.positive?

      raise "ReaderBench deep search incomplete: status=#{status.inspect}, " \
            "reason=#{reason.inspect}, scanned=#{scanned.inspect}"
    end

    def build_lexical_units(reader)
      units = {}
      reader.each_unit do |unit|
        id = unit['identifier']
        next unless id

        units["#{unit['type']}:#{id}"] = JSON.parse(JSON.generate(unit), freeze: true)
      end
      units
    end
  end

  # Human-readable terminal summary printer for profiling receipts.
  module SummaryPrinter
    module_function

    def print(receipt)
      puts "=== Woods End-to-End Profile (scale=#{receipt[:scale]}, " \
           "sha=#{receipt[:git_sha]}, ruby=#{RUBY_VERSION}) ==="
      print_extraction('Full extraction:        ', receipt[:full_extraction])
      print_extraction('Incremental (no-op):    ', receipt[:incremental_noop])
      print_extraction('Incremental (body edit):', receipt[:incremental_method_edit])
      print_subsystems(receipt)
      fps = receipt[:fixture_fingerprints]
      puts "Fixture fingerprints:    #{fps.values.map { |d| d.to_s[0, 10] }.join(' ')}"
      puts "Incremental == clean rebuild: #{receipt[:incremental_matches_clean_rebuild]}"
    end

    def print_extraction(label, data)
      total = data[:total]
      puts format('%<lbl>s %<w>8.2f ms (cpu %<c>7.2f ms) | %<a>10d allocs | gc=%<g>d',
                  lbl: label, w: total[:wall_ms], c: total[:cpu_ms], a: total[:allocations], g: total[:gc_count])
      puts "  Top phases for #{label.strip}"
      data[:top_phases_by_wall].first(8).each do |phase|
        puts format('    %<n>-24s %<w>8.2f ms | %<a>10d allocs | gc=%<g>d',
                    n: phase[:name], w: phase[:wall_ms], a: phase[:allocations], g: phase[:gc_count])
      end
    end

    def print_subsystems(receipt)
      ga = receipt[:graph_analyzer]
      puts format('GraphAnalyzer analyze:  %<a_w>8.2f ms | cycles %<c_w>7.2f ms | ' \
                  'bridges %<b_w>7.2f ms | %<a>10d allocs',
                  a_w: ga.dig(:analyze, :median_wall_ms), c_w: ga.dig(:cycles, :median_wall_ms),
                  b_w: ga.dig(:bridges, :median_wall_ms), a: ga.dig(:analyze, :median_allocations))
      fp = receipt[:flow_precomputer]
      puts format('FlowPrecomputer:        precompute %<pw>7.2f ms (%<pa>d allocs) | ' \
                  'delta %<dw>7.2f ms (%<da>d allocs)',
                  pw: fp.dig(:precompute, :median_wall_ms), pa: fp.dig(:precompute, :median_allocations),
                  dw: fp.dig(:recompute_delta, :median_wall_ms), da: fp.dig(:recompute_delta, :median_allocations))
      rl = receipt[:reader_and_lexical]
      puts format('Reader & Lexical:       edges %<e>6.2f ms | deps %<d>6.2f ms | search %<s>6.2f ms | ' \
                  'lex_build %<lb>7.2f ms | lex_q %<lq>6.2f ms',
                  e: rl.dig(:edges_via, :median_wall_ms), d: rl.dig(:dependents_via, :median_wall_ms),
                  s: rl.dig(:deep_search, :median_wall_ms), lb: rl.dig(:lexical_build, :median_wall_ms),
                  lq: rl.dig(:lexical_query, :median_wall_ms))
    end
  end

  REPO_ROOT = File.expand_path('..', __dir__)
  CLEAN_GIT_ENV = {
    'GIT_DIR' => nil, 'GIT_WORK_TREE' => nil, 'GIT_INDEX_FILE' => nil,
    'GIT_OBJECT_DIRECTORY' => nil, 'GIT_ALTERNATE_OBJECT_DIRECTORIES' => nil, 'GIT_COMMON_DIR' => nil
  }.freeze

  module_function

  def git_sha!
    sha, err, st = Open3.capture3(CLEAN_GIT_ENV, 'git', '-C', REPO_ROOT, 'rev-parse', 'HEAD')
    raise "git rev-parse HEAD failed in #{REPO_ROOT}: #{err.strip}" unless st.success? && !sha.strip.empty?

    sha.strip
  end

  def run(scale: 1)
    Dir.mktmpdir('woods_e2e_profile') { |tmpdir| execute_in(tmpdir, scale: scale) }
  end

  def execute_in(tmpdir, scale:)
    app_root = File.join(tmpdir, 'app')
    out_dir = File.join(tmpdir, 'index')
    clean_dir = File.join(tmpdir, 'clean_rebuild')
    prepare_fixture(app_root, scale: scale)
    full = run_full_extraction(out_dir)
    noop = run_incremental_noop(app_root, out_dir)
    edited = run_incremental_method_edit(app_root, out_dir)
    _, clean_digest = run_full_extraction(clean_dir)
    subsystems = {
      graph: GraphAndFlowBench.bench_graph_analyzer,
      flow: GraphAndFlowBench.bench_flow_precomputer(tmpdir),
      reader: ReaderBench.run(out_dir)
    }
    build_receipt(scale: scale, extractions: { full: full, noop: noop, edited: edited, clean_digest: clean_digest },
                  subsystems: subsystems)
  end

  def prepare_fixture(app_root, scale:)
    AppFixture.build(app_root, scale: scale)
    RailsStub.install(app_root)
    Woods.configuration = Woods::Configuration.new
    Woods.configuration.concurrent_extraction = false
    Woods.configuration.precompute_flows = false
  end

  def build_receipt(scale:, extractions:, subsystems:)
    full, noop, edited, clean_digest = extractions.values_at(:full, :noop, :edited, :clean_digest)
    graph, flow, reader = subsystems.values_at(:graph, :flow, :reader)
    {
      schema_version: 3, ruby_version: RUBY_VERSION, woods_version: Woods::VERSION,
      git_sha: git_sha!, scale: scale,
      full_extraction: full[0], incremental_noop: noop[0], incremental_method_edit: edited[0],
      incremental_matches_clean_rebuild: edited[1] == clean_digest,
      graph_analyzer: graph, flow_precomputer: flow, reader_and_lexical: reader,
      fixture_fingerprints: {
        full_index_digest: full[1], incremental_noop_digest: noop[1],
        incremental_method_edit_digest: edited[1], clean_rebuild_digest: clean_digest,
        graph_analyzer_digest: graph[:digest], flow_precomputer_digest: flow[:digest],
        flow_delta_digest: flow[:delta_digest], reader_and_lexical_digest: reader[:digest]
      }
    }
  end

  def run_full_extraction(out_dir)
    with_env('WOODS_PROFILE' => '1', 'WOODS_PROFILE_OUT' => nil) do
      extractor = Woods::Extractor.new(output_dir: out_dir)
      extractor.extract_all
      [extractor.last_profile.to_h, index_equivalence_digest(out_dir)]
    end
  end

  def run_incremental_noop(app_root, out_dir)
    unchanged = File.join(app_root, 'app/services/billing/processor_0_service.rb')
    with_env('WOODS_PROFILE' => '1', 'WOODS_PROFILE_OUT' => nil) do
      extractor = Woods::Extractor.new(output_dir: out_dir)
      extractor.extract_changed([unchanged])
      [extractor.last_profile.to_h, index_equivalence_digest(out_dir)]
    end
  end

  def run_incremental_method_edit(app_root, out_dir)
    edited = File.join(app_root, 'app/services/billing/processor_0_service.rb')
    updated = File.read(edited).sub('return nil unless order', 'return nil if order.nil? || order.id.nil?')
    File.write(edited, updated)
    with_env('WOODS_PROFILE' => '1', 'WOODS_PROFILE_OUT' => nil) do
      extractor = Woods::Extractor.new(output_dir: out_dir)
      extractor.extract_changed([edited])
      [extractor.last_profile.to_h, index_equivalence_digest(out_dir)]
    end
  end

  # Synthetic fixture fingerprint covering manifest counts, full sorted graph
  # edges, structural summary, and the edited unit's source_code payload (fast
  # synthetic regression guard, not a substitute for booted-Rails equivalence).
  module IndexFingerprint
    module_function

    def digest(out_dir)
      payload = payload_dir(out_dir)
      manifest = read_json(payload, 'manifest.json')
      graph = read_json(payload, 'dependency_graph.json')
      summary = File.read(File.join(payload, 'SUMMARY.md')).sub(/^Generated: .*$/, 'Generated: <ts>')
      Digest::SHA256.hexdigest(JSON.generate(
                                 counts: manifest['counts'].sort.to_h, total_units: manifest['total_units'],
                                 total_chunks: manifest['total_chunks'], graph_stats: graph['stats'],
                                 graph_edges: Hash(graph['edges']).sort.to_h,
                                 edited_source: edited_service_source(payload), summary_lines: summary.lines.sort
                               ))
    end

    def payload_dir(out_dir)
      gen = Woods::Generation.new(output_dir: out_dir).current
      gen&.payload ? File.join(out_dir, gen.payload) : out_dir
    end

    def read_json(payload, rel)
      JSON.parse(File.read(File.join(payload, rel)))
    end

    def edited_service_source(payload)
      id = 'Billing::Processor0Service'
      base = id.gsub('::', '__').gsub(/[^a-zA-Z0-9_-]/, '_')
      path = File.join(payload, 'services', "#{base}_#{Digest::SHA256.hexdigest(id)[0, 8]}.json")
      raise "Missing expected edited unit payload: #{path}" unless File.file?(path)

      source = JSON.parse(File.read(path))['source_code']
      raise "Missing source_code in edited unit payload: #{path}" unless source.is_a?(String) && !source.empty?

      source
    end
  end

  def index_equivalence_digest(out_dir)
    IndexFingerprint.digest(out_dir)
  end

  def with_env(overrides)
    saved = overrides.keys.to_h { |k| [k, ENV.fetch(k, nil)] }
    overrides.each { |k, v| ENV[k] = v }
    yield
  ensure
    saved.each { |k, v| ENV[k] = v }
  end
end

if $PROGRAM_NAME == __FILE__
  scale = Integer(ENV.fetch('SCALE', '1'))
  receipt = WoodsEndToEndProfile.run(scale: scale)
  out_path = ENV.fetch('PROFILE_OUT', nil)
  if out_path && !out_path.empty?
    FileUtils.mkdir_p(File.dirname(out_path))
    File.write(out_path, "#{JSON.pretty_generate(receipt)}\n")
  end
  WoodsEndToEndProfile::SummaryPrinter.print(receipt)
end
