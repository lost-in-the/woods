# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'woods'
require 'woods/dependency_graph'
require 'woods/extracted_unit'
require 'woods/mcp/server'
require 'woods/impact/report'

# `dependents` sorts its rows into families over the whole walk and leads with
# a headline that counts code, with the mapped-test count beside it. Mapped
# tests stay listed whatever `reverse_includes_tests` says; the setting decides
# only whether they count toward the headline.
module DependentsFixture
  # Every row reaching Widget, written out by hand so no assertion below is
  # checked only against what the classifier itself produced.
  ANCHOR = 'Widget'
  # The tests independently expected from the fixture: test_mapping units
  # whose recorded edge to the anchor is test_coverage.
  EXPECTED_DIRECT_MAPPED_TESTS = %w[spec/models/widget_spec.rb].freeze
  # Impact's tests facet for a change to Widget at depth 1: every affected
  # test_mapping unit, whatever relationship reached it.
  EXPECTED_DIRECT_IMPACT_TESTS = %w[spec/models/widget_spec.rb spec/requests/widget_flow_spec.rb].freeze
  EXPECTED_FAMILIES_DEPTH_TWO = {
    'WidgetsController' => 'code', # positive: a controller is code
    'WidgetService' => 'code',
    'spec/models/widget_spec.rb' => 'tests', # mapped test (test_coverage)
    'spec/requests/widget_flow_spec.rb' => 'tests', # near miss: a test, but code_reference
    'spec/support/widget_helpers.rb' => 'tests',
    'CreateWidgets' => 'schema',
    'AGENTS.md' => 'docs', # agent instruction file: a doc unit, no path rule
    'Mystery' => 'other', # unknown: a type no family names
    'spec/controllers/widgets_controller_spec.rb' => 'tests' # mapped test at depth 2
  }.freeze
  EXPECTED_MAPPED_DEPTH_TWO = %w[spec/controllers/widgets_controller_spec.rb spec/models/widget_spec.rb].freeze

  module_function

  def unit(identifier, type, dependencies = [], source: "# #{identifier}\n")
    record = Woods::ExtractedUnit.new(type: type, identifier: identifier, file_path: "/app/#{identifier}")
    record.source_code = source
    record.dependencies = dependencies.map do |target, target_type, via|
      { type: target_type, target: target, via: via }
    end
    record
  end

  def fixture_units(anchor_source: "class Widget; end\n")
    [
      unit(ANCHOR, :model, source: anchor_source),
      unit('WidgetsController', :controller, [[ANCHOR, :model, :code_reference]]),
      unit('WidgetService', :service, [[ANCHOR, :model, :code_reference]]),
      unit('spec/models/widget_spec.rb', :test_mapping, [[ANCHOR, :model, :test_coverage]]),
      unit('spec/requests/widget_flow_spec.rb', :test_mapping, [[ANCHOR, :model, :code_reference]]),
      unit('spec/support/widget_helpers.rb', :test_support, [[ANCHOR, :model, :code_reference]]),
      unit('CreateWidgets', :migration, [[ANCHOR, :model, :code_reference]]),
      unit('AGENTS.md', :doc, [[ANCHOR, :model, :documents]]),
      unit('Mystery', :custom_thing, [[ANCHOR, :model, :code_reference]]),
      unit('spec/controllers/widgets_controller_spec.rb', :test_mapping,
           [['WidgetsController', :controller, :test_coverage]])
    ]
  end

  # Publishes one generation the way the writer lays it out: unit files, a
  # manifest and the graph DependencyGraph serializes for those units.
  def publish(root, number, units)
    payload = File.join(root, 'payloads', "gen-#{number}")
    graph = Woods::DependencyGraph.new
    units.each { |record| graph.register(record) }
    by_dir = write_units(payload, units)
    File.write(File.join(payload, 'manifest.json'),
               JSON.generate('git_sha' => 'a' * 40, 'total_units' => by_dir.values.sum(&:size),
                             'counts' => by_dir.transform_values(&:size)))
    File.write(File.join(payload, 'dependency_graph.json'), JSON.generate(graph.to_h))
    # Renamed into place, as the writer publishes, so a reader sees a new marker.
    marker = File.join(root, "generation.json.#{number}.tmp")
    File.write(marker, JSON.generate('number' => number, 'token' => "token-#{number}",
                                     'payload' => "payloads/gen-#{number}"))
    File.rename(marker, File.join(root, 'generation.json'))
  end

  # A type no reader knows stays in the graph only, as an unrecognized
  # producer's node would.
  def write_units(payload, units)
    directories = Woods::MCP::IndexReader::UNIT_TYPE_TO_DIR
    by_dir = units.select { |record| directories.key?(record.type.to_s) }
                  .group_by { |record| directories.fetch(record.type.to_s) }
    by_dir.each do |dir, records|
      FileUtils.mkdir_p(File.join(payload, dir))
      records.each { |record| File.write(File.join(payload, dir, unit_filename(record)), JSON.generate(record.to_h)) }
      File.write(File.join(payload, dir, '_index.json'),
                 JSON.generate(records.map { |record| { identifier: record.identifier } }))
    end
  end

  def unit_filename(record)
    "#{record.identifier.gsub(/[^a-zA-Z0-9_-]/, '_')}_#{Digest::SHA256.hexdigest(record.identifier)[0, 8]}.json"
  end
end

RSpec.describe 'dependents families and headline' do
  let(:fx) { DependentsFixture }

  around do |example|
    Dir.mktmpdir('woods-dependents-families') do |dir|
      @root = dir
      original = ENV.delete(Woods::MCP::DependentFamilies::ENV_KEY)
      Woods.configuration = Woods::Configuration.new
      example.run
    ensure
      original ? ENV[Woods::MCP::DependentFamilies::ENV_KEY] = original : ENV.delete(Woods::MCP::DependentFamilies::ENV_KEY)
    end
  end

  def call(format, root: @root, **arguments)
    server = Woods::MCP::Server.build(index_dir: root, response_format: format, warmup: false)
    request = { jsonrpc: '2.0', id: 1, method: 'tools/call', params: { name: 'dependents', arguments: arguments } }
    JSON.parse(server.handle_json(JSON.generate(request))).fetch('result')
  end

  def data(format: :json, root: @root, **arguments)
    call(format, root: root, **arguments).dig('structuredContent', 'data')
  end

  def listed(payload)
    payload.fetch('nodes').transform_values { |entry| entry.except('family', 'mapped_test') }
  end

  def with_setting(value)
    Woods.configuration.reverse_includes_tests = value
    yield
  ensure
    Woods.configuration.reverse_includes_tests = false
  end

  describe Woods::MCP::DependentFamilies do
    # Truth table: published type(s) -> family. Only published types decide.
    {
      %w[model] => 'code', %w[controller] => 'code', %w[service] => 'code', %w[view_template] => 'code',
      %w[test_mapping] => 'tests', %w[test_support] => 'tests', %w[factory] => 'tests',
      %w[database_table] => 'schema', %w[migration] => 'schema', %w[database_view] => 'schema',
      %w[doc] => 'docs',
      %w[route] => 'other', %w[config_file] => 'other', %w[custom_thing] => 'other', [nil] => 'other', [] => 'other',
      %w[scheduled_job] => 'code', %w[event] => 'code', %w[caching] => 'code',
      %w[external_consumer] => 'schema',
      %w[model service] => 'code', %w[model test_mapping] => 'other'
    }.each do |types, family|
      it "classifies #{types.inspect} as #{family}" do
        expect(described_class.family_for(types)).to eq(family)
      end
    end

    # Truth table: environment, configuration -> whether the headline counts mapped tests.
    [[nil, false, false], [nil, true, true], ['1', false, true], ['true', false, true],
     ['0', true, false], ['off', true, false], ['', true, true]].each do |env, config, expected|
      it "reads the headline setting as #{expected} for env=#{env.inspect}, config=#{config}" do
        Woods.configuration.reverse_includes_tests = config
        env.nil? ? ENV.delete(described_class::ENV_KEY) : ENV[described_class::ENV_KEY] = env
        expect(described_class.include_tests?).to be(expected)
      end
    end

    it 'gives every published unit type a family on purpose' do
      lists = { 'code' => described_class::CODE, 'tests' => described_class::TESTS,
                'schema' => described_class::SCHEMA, 'docs' => described_class::DOCS,
                'other' => described_class::OTHER }
      Woods::MCP::IndexReader::UNIT_TYPE_TO_DIR.each_key do |type|
        named = lists.select { |_family, types| types.include?(type) }.keys
        expect(named.size).to eq(1), "#{type} is listed under #{named.inspect}; list it under exactly one family"
        expect(described_class.family_for([type])).to eq(named.first), type
      end
      expect(lists.values.flatten - Woods::MCP::IndexReader::UNIT_TYPE_TO_DIR.keys).to be_empty
    end

    it 'ignores an unrecognized environment value with a warning and keeps the configuration' do
      ENV[described_class::ENV_KEY] = 'maybe'
      [true, false].each do |config|
        Woods.configuration.reverse_includes_tests = config
        expect { expect(described_class.include_tests?).to be(config) }
          .to output(/Ignoring WOODS_REVERSE_INCLUDES_TESTS="maybe"/).to_stderr
      end
    end

    it 'defaults the setting to false and refuses a value that is not a boolean' do
      expect(Woods::Configuration.new.reverse_includes_tests).to be(false)
      expect { Woods.configuration.reverse_includes_tests = 'yes' }.to raise_error(Woods::ConfigurationError)
    end

    it 'is not an extraction setting, so changing it never asks for re-extraction' do
      expect(Woods::Configuration::EXTRACTION_KEYS).not_to include(:reverse_includes_tests)
      before = Woods.configuration.extraction_fingerprint
      Woods.configuration.reverse_includes_tests = true
      expect(Woods.configuration.extraction_fingerprint).to eq(before)
    end
  end

  describe 'counts' do
    before { fx.publish(@root, 1, fx.fixture_units) }

    it 'sorts every row into one family, so the families add up to the total' do
      payload = data(identifier: fx::ANCHOR, depth: 2)
      families = payload.fetch('nodes').except(fx::ANCHOR).transform_values { |entry| entry.fetch('family') }
      expect(families).to eq(fx::EXPECTED_FAMILIES_DEPTH_TWO)
      counts = payload.fetch('dependent_counts')
      expect(counts.fetch('families')).to eq('code' => 2, 'tests' => 4, 'schema' => 1, 'docs' => 1, 'other' => 1)
      expect(counts.fetch('families').values.sum).to eq(counts.fetch('total'))
      expect(counts.fetch('total')).to eq(fx::EXPECTED_FAMILIES_DEPTH_TWO.size)
    end

    it 'counts code in the headline with mapped tests beside it, by default' do
      counts = data(identifier: fx::ANCHOR, depth: 2).fetch('dependent_counts')
      expect(counts).to include('headline' => 2, 'mapped_tests' => fx::EXPECTED_MAPPED_DEPTH_TWO.size,
                                'reverse_includes_tests' => false, 'exact' => true, 'bound' => 'exact',
                                'scope' => 'whole_traversal')
    end

    it 'marks only test_mapping rows reached through test_coverage as mapped tests, with the raw relationship' do
      nodes = data(identifier: fx::ANCHOR, depth: 2).fetch('nodes')
      mapped = nodes.select { |_id, entry| entry.key?('mapped_test') }
      expect(mapped.keys.sort).to eq(fx::EXPECTED_MAPPED_DEPTH_TWO)
      expect(mapped.values.map { |entry| entry.fetch('mapped_test') }.uniq)
        .to eq([{ 'via' => 'test_coverage', 'direction' => 'test_to_subject' }])
      # Near miss: a spec that reaches Widget by code_reference is a test, not a mapped test.
      expect(nodes.fetch('spec/requests/widget_flow_spec.rb')).not_to have_key('mapped_test')
    end

    it 'lists the same rows with the setting on and off; only the headline differs' do
      off = data(identifier: fx::ANCHOR, depth: 2)
      on = with_setting(true) { data(identifier: fx::ANCHOR, depth: 2) }
      expect(on.fetch('nodes')).to eq(off.fetch('nodes'))
      expect(on.except('dependent_counts')).to eq(off.except('dependent_counts'))
      expect(on.fetch('dependent_counts').except('headline', 'reverse_includes_tests'))
        .to eq(off.fetch('dependent_counts').except('headline', 'reverse_includes_tests'))
      expect(on.dig('dependent_counts', 'headline')).to eq(2 + fx::EXPECTED_MAPPED_DEPTH_TWO.size)
      expect(on.dig('dependent_counts', 'reverse_includes_tests')).to be(true)
    end

    it 'lists the same rows as the traversal did before families existed, in every page and budget' do
      reader = Woods::MCP::IndexReader.new(@root)
      [{}, { limit: 3 }, { limit: 3, offset: 3 }, { max_nodes: 4 }, { max_edges: 3 }, { types: ['test_mapping'] },
       { via: ['test_coverage'] }, { explain: true }].each do |options|
        arguments = { identifier: fx::ANCHOR, depth: 2 }.merge(options)
        raw = reader.traverse_dependents(fx::ANCHOR, depth: 2, types: options[:types], via: options[:via],
                                                     max_nodes: options.fetch(:max_nodes, 1000),
                                                     max_edges: options.fetch(:max_edges, 10_000),
                                                     explain: options.fetch(:explain, false))
        Woods::MCP::Server.send(:paginate_traversal_nodes, raw, options.fetch(:limit, 50), options.fetch(:offset, 0))
        expected = JSON.parse(JSON.generate(raw.fetch(:nodes)))
        [false, true].each do |setting|
          payload = with_setting(setting) { data(**arguments) }
          expect(listed(payload)).to eq(expected), "#{options.inspect}, setting #{setting}"
        end
      end
    end

    it 'counts the whole traversal, not the page' do
      whole = data(identifier: fx::ANCHOR, depth: 2).fetch('dependent_counts')
      [{ limit: 1 }, { limit: 2, offset: 4 }, { limit: 5, offset: 50 }].each do |page|
        expect(data(identifier: fx::ANCHOR, depth: 2, **page).fetch('dependent_counts')).to eq(whole)
      end
    end

    it 'reports budget-limited counts as lower bounds' do
      counts = data(identifier: fx::ANCHOR, depth: 2, max_nodes: 3).fetch('dependent_counts')
      expect(counts).to include('exact' => false, 'bound' => 'lower_bound', 'total' => 2)
      expect(counts.fetch('families').values.sum).to eq(2)
    end

    it 'counts the same families with and without explain' do
      expect(data(identifier: fx::ANCHOR, depth: 2, explain: true).fetch('dependent_counts'))
        .to eq(data(identifier: fx::ANCHOR, depth: 2).fetch('dependent_counts'))
    end

    it 'adds no counts to dependencies or to an identifier the index lacks' do
      expect(data(identifier: 'spec/models/widget_spec.rb', depth: 1).fetch('dependent_counts'))
        .to include('total' => 0, 'headline' => 0, 'mapped_tests' => 0)
      server = Woods::MCP::Server.build(index_dir: @root, response_format: :json, warmup: false)
      request = { jsonrpc: '2.0', id: 1, method: 'tools/call',
                  params: { name: 'dependencies', arguments: { identifier: 'WidgetService' } } }
      forward = JSON.parse(server.handle_json(JSON.generate(request))).dig('result', 'structuredContent', 'data')
      expect(forward).not_to have_key('dependent_counts')
      expect(forward.fetch('nodes').values).to all(satisfy { |entry| !entry.key?('family') })
      expect(data(identifier: 'Absent')).not_to have_key('dependent_counts')
    end
  end

  describe 'one generation per answer' do
    # A generation that publishes after the walk and before the mapped-test
    # check must not change the answer: the spec's edge becomes a
    # code_reference in generation 2, so reading it there would unmark it.
    def republish_after_walk
      reader_class = Woods::MCP::IndexReader
      allow_any_instance_of(reader_class).to receive(:traverse_dependents).and_wrap_original do |walk, *args, **options|
        walked = walk.call(*args, **options)
        units = fx.fixture_units.map do |record|
          next record unless record.identifier == 'spec/models/widget_spec.rb'

          fx.unit(record.identifier, :test_mapping, [[fx::ANCHOR, :model, :code_reference]])
        end
        fx.publish(@root, 2, units)
        walked
      end
    end

    def mapped_rows(payload)
      payload.fetch('nodes').select { |_id, entry| entry.key?('mapped_test') }.keys.sort
    end

    [false, true].each do |explain|
      it "classifies the rows of the generation it walked, explain=#{explain}" do
        fx.publish(@root, 1, fx.fixture_units)
        server = Woods::MCP::Server.build(index_dir: @root, response_format: :json, warmup: false)
        republish_after_walk
        # The handler itself, without the per-request pin the dispatcher adds.
        response = server.tools.fetch('dependents').call(identifier: fx::ANCHOR, depth: 1, explain: explain,
                                                         server_context: {})
        payload = response.structured_content.fetch(:data)
        payload = JSON.parse(JSON.generate(payload))
        expect(mapped_rows(payload)).to eq(fx::EXPECTED_DIRECT_MAPPED_TESTS)
        expect(payload.dig('dependent_counts', 'mapped_tests')).to eq(1)
      end
    end
  end

  describe 'rendering' do
    before { fx.publish(@root, 1, fx.fixture_units) }

    it 'prints the headline, the mapped-test count and the families in every text renderer' do
      %i[markdown plain claude].each do |format|
        text = call(format, identifier: fx::ANCHOR, depth: 2).dig('content', 0, 'text')
        expect(text).to include('Recorded dependents: 2 (code); Mapped tests: 2 (listed, not counted).')
        expect(text).to include('By family: code 2, tests 4, schema 1, docs 1, other 1; ' \
                                'total 9 over the whole traversal.')
        expect(text.scan('(Mapped test)').size).to eq(2)
        expect(text).not_to match(/will break/i)
      end
      json = JSON.parse(call(:json, identifier: fx::ANCHOR, depth: 2).dig('content', 0, 'text'))
      expect(json.fetch('dependent_counts')).to include('headline' => 2, 'mapped_tests' => 2)
    end

    it 'says the headline includes mapped tests when the setting is on' do
      with_setting(true) do
        text = call(:markdown, identifier: fx::ANCHOR, depth: 2).dig('content', 0, 'text')
        expect(text).to include('Recorded dependents: 4 (code and Mapped tests); ' \
                                'Mapped tests: 2 (counted in the headline).')
      end
    end

    it 'prints budget-limited counts as lower bounds' do
      text = call(:plain, identifier: fx::ANCHOR, depth: 2, max_nodes: 3).dig('content', 0, 'text')
      expect(text).to include('Recorded dependents: at least ')
      expect(text).to include('(lower bounds: the walk stopped early)')
    end

    it 'formats the counts it is given instead of recounting the rows' do
      supplied = { root: fx::ANCHOR, found: true, nodes: { fx::ANCHOR => { type: 'model', depth: 0, deps: [] } },
                   dependent_counts: { exact: true, headline: 41, mapped_tests: 7, reverse_includes_tests: false,
                                       total: 99, families: { code: 41, tests: 8, schema: 0, docs: 50, other: 0 } } }
      %i[markdown plain claude].each do |format|
        text = Woods::MCP::ToolResponseRenderer.for(format).render(:dependents, supplied)
        expect(text).to include('Recorded dependents: 41 (code); Mapped tests: 7')
        expect(text).to include('total 99')
      end
      expect(JSON.parse(Woods::MCP::ToolResponseRenderer.for(:json).render(:dependents, supplied))
               .fetch('dependent_counts')).to include('headline' => 41, 'total' => 99)
    end
  end

  describe 'woods_status' do
    before { fx.publish(@root, 1, fx.fixture_units) }

    def status_features
      server = Woods::MCP::Server.build(index_dir: @root, response_format: :json, warmup: false)
      request = { jsonrpc: '2.0', id: 1, method: 'tools/call',
                  params: { name: 'woods_status', arguments: { worktrees: 'none' } } }
      text = JSON.parse(server.handle_json(JSON.generate(request))).dig('result', 'content', 0, 'text')
      JSON.parse(text).fetch('features')
    end

    it 'reports the headline setting from the configuration and from the environment' do
      expect(status_features.fetch('reverse_includes_tests')).to be(false)
      with_setting(true) { expect(status_features.fetch('reverse_includes_tests')).to be(true) }
      ENV[Woods::MCP::DependentFamilies::ENV_KEY] = '1'
      expect(status_features.fetch('reverse_includes_tests')).to be(true)
    end
  end

  describe 'impact consistency' do
    it 'lists the direct mapped tests of a changed anchor inside the impact tests facet' do
      fx.publish(@root, 1, fx.fixture_units)
      fx.publish(@root, 2, fx.fixture_units(anchor_source: "class Widget\n  def changed; end\nend\n"))

      mapped = data(identifier: fx::ANCHOR, depth: 1).fetch('nodes').select do |_id, entry|
        entry.key?('mapped_test')
      end.keys
      report = Woods::Impact::Report.compare(@root, from: 'gen:1', to: 'now', depth: 1).to_h
      expect(report.fetch('changed').map { |change| change.values_at('identifier', 'status') })
        .to eq([[fx::ANCHOR, 'modified']])
      impact_tests = report.fetch('tests').filter_map { |item| item['identifier'] if item['type'] == 'test_mapping' }
      expect(report.fetch('unknowns').map { |item| item['kind'] }).not_to include('node_budget', 'edge_budget')

      by_coverage = report.fetch('tests').select do |item|
        item['evidence'].any? { |evidence| evidence['via'] == 'test_coverage' }
      end
      # Each side is checked against a list written out from the fixture, so
      # an empty set cannot pass. Impact also suggests the request spec that
      # reaches Widget by code_reference; dependents lists it, but not as a
      # mapped test, which is why the relation is a subset and not equality.
      expect(mapped.sort).to eq(fx::EXPECTED_DIRECT_MAPPED_TESTS)
      expect(by_coverage.map { |item| item['identifier'] }.uniq.sort).to eq(fx::EXPECTED_DIRECT_MAPPED_TESTS)
      expect(impact_tests.uniq.sort).to eq(fx::EXPECTED_DIRECT_IMPACT_TESTS)
      expect(mapped - impact_tests).to be_empty
    end
  end

  describe 'hub cost', :perf do
    def median_ms(samples)
      samples.sort[samples.size / 2] * 1000
    end

    def timed
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      yield
      Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    end

    # 4000 direct dependents, a third of them mapped specs; every code caller
    # has its own mapped spec one hop further out.
    def hub_units
      dependents = Array.new(4000) do |i|
        if (i % 3).zero?
          [fx.unit("spec/models/hub_#{i}_spec.rb", :test_mapping, [['Hub', :model, :test_coverage]])]
        else
          [fx.unit("HubCaller#{i}", :service, [['Hub', :model, :code_reference]]),
           fx.unit("spec/services/hub_caller_#{i}_spec.rb", :test_mapping,
                   [["HubCaller#{i}", :service, :test_coverage]])]
        end
      end
      [fx.unit('Hub', :model)] + dependents.flatten
    end

    # Report only (no threshold): what classifying adds to one call over a hub.
    it 'measures the per-query cost of families on a hub-sized traversal' do
      fx.publish(@root, 1, hub_units)
      server = Woods::MCP::Server.build(index_dir: @root, response_format: :markdown, warmup: false)
      [{ depth: 1, max_nodes: 10_000 }, { depth: 2, max_nodes: 1000 }, { depth: 2, max_nodes: 10_000 }].each do |walk|
        request = JSON.generate(jsonrpc: '2.0', id: 1, method: 'tools/call',
                                params: { name: 'dependents', arguments: { identifier: 'Hub', **walk } })
        server.handle_json(request)
        calls = Array.new(5) { timed { server.handle_json(request) } }
        # Cold: the first classification after a generation loads also
        # normalizes its forward edges, once. Warm: every later query.
        reader = Woods::MCP::IndexReader.new(@root)
        rows = reader.traverse_dependents('Hub', **walk).fetch(:nodes).size - 1
        cold = timed do
          Woods::MCP::DependentFamilies.annotate(reader.traverse_dependents('Hub', **walk),
                                                 vias: reader.method(:recorded_vias))
        end
        classify = Array.new(5) do
          result = reader.traverse_dependents('Hub', **walk)
          timed { Woods::MCP::DependentFamilies.annotate(result, vias: reader.method(:recorded_vias)) }
        end
        warn format('dependents hub %<walk>s: %<rows>d rows, call median %<call>.1f ms, ' \
                    'classify median %<classify>.1f ms (first after load %<cold>.1f ms)',
                    walk: walk.inspect, rows: rows, call: median_ms(calls), classify: median_ms(classify),
                    cold: cold * 1000)
      end
    end
  end
end
