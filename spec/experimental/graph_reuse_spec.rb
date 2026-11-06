# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'pathname'
require 'woods/experimental/incremental_reuse'

RSpec.describe 'Complete graph and analyzer-input reuse experiment' do
  include_context 'isolated Woods runtime'
  around do |example|
    Dir.mktmpdir('woods-graph-reuse') do |root|
      @root = Pathname.new(root)
      example.run
    end
  end
  before do
    @previous_pilot = ENV.fetch('WOODS_EXPERIMENTAL_INCREMENTAL_REUSE', nil)
    ENV['WOODS_EXPERIMENTAL_INCREMENTAL_REUSE'] = 'combined'
    Woods.configuration.concurrent_extraction = false
    root = @root
    rails = Class.new
    rails.define_singleton_method(:root) { root }
    rails.define_singleton_method(:version) { '8.1.4' }
    stub_const('Rails', rails)
  end
  after do
    ENV['WOODS_EXPERIMENTAL_INCREMENTAL_REUSE'] = @previous_pilot
    Woods::Experimental::IncrementalReuse.reset!
  end
  def unit(type, id, deps = [])
    Woods::ExtractedUnit.new(type: type, identifier: id, file_path: File.join(@root, 'app', "#{id}.rb")).tap { |u| u.dependencies = deps }
  end

  # The fixture builds a graph, exact persisted bytes and an independent analyzer result together.
  # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
  def writer
    Woods::Experimental::IncrementalReuse.reset!
    graph = Woods::DependencyGraph.new
    graph.register(unit(:model, 'A', [{ target: 'B', via: 'code_reference' }]))
    graph.register(unit(:service, 'B'))
    graph.register(unit(:doc, 'guide'))
    route = unit(:route, 'route_missing', [{ target: 'MissingController', via: 'route_dispatch' }])
    route.metadata = { controller: 'MissingController', action: 'show' }
    graph.register(route)
    extractor = Woods::Extractor.allocate
    allow(extractor).to receive(:output_dir).and_return(@root)
    extractor.instance_variable_set(:@dependency_graph, graph)
    extractor.instance_variable_set(:@resolved, false)
    extractor.instance_variable_set(:@own, true)
    extractor.define_singleton_method(:defined_controller?) { |_id| @resolved }
    extractor.define_singleton_method(:application_source?) { |_path| @own }
    allow(extractor).to receive(:payload_dir).and_return(@root)
    allow(extractor).to receive(:payload_writes_durable?).and_return(false)
    data = graph.to_h
    data[:pagerank] = graph.pagerank.sort.to_h
    bytes = JSON.pretty_generate(data)
    File.binwrite(@root.join('dependency_graph.json'), bytes)
    body = extractor.send(:build_graph_analyzer).analyze
    raise 'fixture did not exercise runtime controller resolution' unless body[:unresolvable_routes].any? do |r|
      r[:controller] == 'MissingController'
    end

    analysis = JSON.pretty_generate(body.merge(graph_sha: Digest::SHA256.hexdigest(bytes), generated_at: 'baseline'))
    File.write(@root.join('graph_analysis.json'), analysis)
    witness = Woods::Experimental::IncrementalReuse::GraphReuse::Witness.key(extractor, graph)
    cache = Woods::Experimental::IncrementalReuse::GraphReuse::Cache.new(
      graph_bytes: bytes, analysis_bytes: analysis, witness: witness
    )
    extractor.instance_variable_set(:@pilot_graph, cache)
    extractor
  end

  # rubocop:enable Metrics/AbcSize, Metrics/MethodLength

  def cycle(extractor)
    extractor.instance_variable_set(:@reuse_graph_unchanged, false)
    Woods::Experimental::IncrementalReuse.run(extractor) do |context|
      context.incremental = true
      context.session.graph = extractor.instance_variable_get(:@pilot_graph)
      extractor.send(:write_dependency_graph)
      extractor.send(:write_incremental_graph_analysis)
    end
  end
  it 'reuses exact immutable graph bytes and analysis when complete inputs match' do
    extractor = writer
    bytes = File.binread(@root.join('dependency_graph.json'))
    inode = File.stat(@root.join('dependency_graph.json')).ino
    expect(Woods::GraphAnalyzer).not_to receive(:new)
    cycle(extractor)
    expect(Woods::Experimental::IncrementalReuse.stats[:counts]).to include(graph_reused: 1, analysis_reused: 1)
    expect(File.binread(@root.join('dependency_graph.json'))).to eq(bytes)
    expect(File.stat(@root.join('dependency_graph.json')).ino).to eq(inode)
  end
  { volatile_dependency_ratio: 4.0, volatile_dependency_limit_per_target: 2, graph_cycle_limit: 3,
    graph_cycle_max_length: 4 }.each do |option, value|
    it "invalidates analysis when #{option} changes despite equal graph bytes" do
      extractor = writer
      Woods.configuration.public_send("#{option}=", value)
      expect(extractor).to receive(:build_graph_analyzer).and_call_original
      cycle(extractor)
      expect(Woods::Experimental::IncrementalReuse.stats[:counts]).to include(graph_reused: 1, analysis_misses: 1)
    end
  end
  it 're-evaluates runtime missing-controller resolution outside graph bytes' do
    extractor = writer
    extractor.instance_variable_set(:@resolved, true)
    cycle(extractor)
    body = JSON.parse(File.read(@root.join('graph_analysis.json')))
    expect(Woods::Experimental::IncrementalReuse.stats[:counts][:analysis_misses]).to eq(1)
    expect(body['unresolvable_routes']).to eq([])
  end
  it 're-evaluates application-source predicate results outside graph bytes' do
    extractor = writer
    extractor.instance_variable_set(:@own, false)
    expect(extractor).to receive(:build_graph_analyzer).and_call_original
    cycle(extractor)
    expect(Woods::Experimental::IncrementalReuse.stats[:counts][:analysis_misses]).to eq(1)
  end
  it 'invalidates complete graph reuse for volatile node facts with unchanged edges' do
    extractor = writer

    extractor.instance_variable_get(:@dependency_graph).annotate('A', type: :model, commit_count: 30,
                                                                      change_frequency: 4)
    cycle(extractor)
    expect(Woods::Experimental::IncrementalReuse.stats[:counts]).to include(graph_misses: 1, analysis_misses: 1)
    graph = JSON.parse(File.read(@root.join('dependency_graph.json')))
    expect(graph['nodes']['A']['commit_count']).to eq(30)
  end
  it 'invalidates for source size/package changes, additions, removals and typed collisions' do
    [->(g) { g.annotate('A', type: :model, loc: 99, package: 'changed') },
     ->(g) { g.register(unit(:job, 'B')) }, ->(g) { g.remove('A') },
     ->(g) { g.register(unit(:service, 'C')) }].each do |mutation|
      extractor = writer
      mutation.call(extractor.instance_variable_get(:@dependency_graph))
      cycle(extractor)
      expect(Woods::Experimental::IncrementalReuse.stats[:counts]).to include(graph_misses: 1, analysis_misses: 1)
    end
  end
  it 'does not confuse equal-node-count edge edits with graph equality' do
    extractor = writer
    extractor.instance_variable_get(:@dependency_graph).register(unit(:model, 'A',
                                                                      [{ target: 'B', via: 'different_relationship' }]))
    cycle(extractor)

    expect(Woods::Experimental::IncrementalReuse.stats[:counts]).to include(graph_misses: 1, analysis_misses: 1)
  end
  it 'invalidates cached analysis for changed code constants' do
    extractor = writer
    stub_const('Woods::GraphAnalyzer::VOLATILE_MIN_COMMITS', 99)
    cycle(extractor)
    expect(Woods::Experimental::IncrementalReuse.stats[:counts][:analysis_misses]).to eq(1)
  end
  it 'never swallows a graph read failure or analysis atomic-write failure' do
    extractor = writer
    error = IOError.new('graph read failed')
    allow(Woods::AtomicFile).to receive(:read).and_raise(error)
    expect { cycle(extractor) }.to(raise_error { |e| expect(e).to equal(error) })
    allow(Woods::AtomicFile).to receive(:read).and_call_original
    allow(Woods::AtomicFile).to receive(:write).and_raise(error)
    expect { cycle(extractor) }.to(raise_error { |e| expect(e).to equal(error) })
  end
  it 'refuses a cache whose analysis is bound to a different graph and returns owned bodies' do
    expect do
      Woods::Experimental::IncrementalReuse::GraphReuse::Cache.new(
        graph_bytes: '{}', analysis_bytes: '{"graph_sha":"bad"}', witness: 'x'
      )
    end.to raise_error(/graph mismatch/)
    extractor = writer
    a = extractor.instance_variable_get(:@pilot_graph).analysis
    a[:hubs].clear
    expect(extractor.instance_variable_get(:@pilot_graph).analysis).not_to equal(a)
  end
  it 'does not resolve a controller for a route without an action' do
    extractor = writer
    g = extractor.instance_variable_get(:@dependency_graph)
    g.register(unit(:route, 'ignored_route', [{ target: 'IgnoredController', via: 'route_dispatch' }]))
    allow(extractor).to receive(:defined_controller?).and_call_original
    expect(extractor).not_to receive(:defined_controller?).with('IgnoredController')
    Woods::Experimental::IncrementalReuse::GraphReuse::Witness.key(extractor, g)
  end
  it 'resolves only the first dispatch target, as the analyzer does' do
    extractor = writer
    g = extractor.instance_variable_get(:@dependency_graph)
    route = unit(:route, 'route_missing',
                 [{ target: 'MissingController', via: 'route_dispatch' },
                  { target: 'UnusedSecondController', via: 'route_dispatch' }])
    route.metadata = { controller: 'MissingController', action: 'show' }
    g.register(route)
    dispatches = g.edge_records('route_missing', type: :route).select { |edge| edge[:via] == :route_dispatch }
    targets = dispatches.map { |edge| edge[:target] }
    allow(extractor).to receive(:defined_controller?).and_call_original
    expect(extractor).not_to receive(:defined_controller?).with(targets.last)
    Woods::Experimental::IncrementalReuse::GraphReuse::Witness.key(extractor, g)
  end
end
