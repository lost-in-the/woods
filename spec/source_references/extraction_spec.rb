# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'woods/extractor'
require 'woods/source_references/cache'

RSpec.describe 'Source-reference extraction integration' do
  around do |example|
    Dir.mktmpdir('woods-reference-extraction') do |root|
      @root = root
      @output = File.join(root, 'index')
      example.run
    end
  end

  before do
    stub_const('Rails', double('Rails', root: Pathname.new(@root), logger: double('Logger').as_null_object))
    stub_const('RefIntegrationCaller', Class.new)
    stub_const('RefIntegrationTarget', Class.new)
    write_source('caller', 'class RefIntegrationCaller; def call; RefIntegrationTarget.new; end; end')
    write_source('target', 'class RefIntegrationTarget; end')
    allow(Woods::SourceInputs::Handoff).to receive(:read).and_return(nil)
  end

  def write_source(name, source)
    path = File.join(@root, "app/models/#{name}.rb")
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, source)
    path
  end

  def unit(identifier, name)
    unit = Woods::ExtractedUnit.new(type: :poro, identifier: identifier,
                                    file_path: File.join(@root, "app/models/#{name}.rb"))
    unit.source_code = '# formatted summary is not original source'
    unit.metadata = { git: { commit_count: 7, change_frequency: 'active' }, custom: ['keep'] }
    unit.chunks = [{ id: 'kept-chunk', content: 'keep' }]
    unit
  end

  def full(target: true)
    extractor = Woods::Extractor.new(output_dir: @output)
    extractor.send(:begin_source_inputs, 'full')
    extractor.send(:begin_payload!)
    units = [unit('RefIntegrationCaller', 'caller')]
    units << unit('RefIntegrationTarget', 'target') if target
    extractor.instance_variable_set(:@results, { poros: units })
    extractor.send(:enrich_source_references_full)
    graph = Woods::DependencyGraph.new
    units.each { |value| graph.register(value) }
    extractor.instance_variable_set(:@dependency_graph, graph)
    extractor.send(:resolve_dependents)
    units.each do |value|
      extractor.send(:write_unit_file, unit_path(extractor, value.identifier), value)
    end
    extractor.send(:write_dependency_graph)
    extractor.instance_variable_get(:@source_inputs).consume_extractor(:poros, units)
    extractor.instance_variable_set(:@eager_load_complete, true)
    extractor.send(:publish_generation, 'full')
    extractor.raise_on_publication_failure!
    extractor
  end

  def incremental
    extractor = Woods::Extractor.new(output_dir: @output)
    allow(extractor).to receive(:safe_eager_load!)
    extractor.send(:prepare_incremental_run)
    extractor
  end

  def unit_path(extractor, identifier)
    extractor.payload_dir.join('poros', extractor.send(:collision_safe_filename, identifier))
  end

  def read_unit(extractor, identifier)
    JSON.parse(File.read(unit_path(extractor, identifier)))
  end

  def expected_edge
    { 'type' => 'poro', 'target' => 'RefIntegrationTarget', 'via' => 'code_reference' }
  end

  it 'uses original full-extraction source and publishes matching forward/reverse graph edges with its cache' do
    extractor = full
    data = read_unit(extractor, 'RefIntegrationCaller')
    expect(data['dependencies']).to eq([expected_edge])
    expect(extractor.dependency_graph.dependents_of('RefIntegrationTarget')).to eq(['RefIntegrationCaller'])
    cache = Woods::SourceReferences::Cache.read(extractor.payload_dir.join(Woods::SourceReferences::Cache::FILE_NAME))
    owner = cache['owners'].find { |record| record['identifier'] == 'RefIntegrationCaller' }
    expect(owner).to include('added' => [expected_edge])
    expect(extractor.dependency_graph.to_h[:reverse_via]['RefIntegrationTarget']).to include(
      source: 'RefIntegrationCaller', source_type: :poro, via: :code_reference
    )
  end

  it 'connects an unchanged caller when a target arrives while preserving metadata and git graph facts' do
    previous = full(target: false)
    before = read_unit(previous, 'RefIntegrationCaller')
    extractor = incremental
    graph = extractor.dependency_graph
    attributes = { commit_count: 7, change_frequency: 'active', package: 'payments', database: 'primary',
                   table: 'payments', foreign_key_tables: ['accounts'], enforce_dependencies: true, kind: 'custom' }
    graph.annotate('RefIntegrationCaller', type: :poro, **attributes)
    allow(extractor).to receive(:annotate_package)
    allow(extractor).to receive(:source_consumer_failed?).and_return(false)
    affected = Set.new
    extractor.send(:register_and_write, :poros, [unit('RefIntegrationTarget', 'target')], affected)
    touched = extractor.send(:enrich_source_references_incremental, affected)
    extractor.send(:rewrite_unit_json, 'RefIntegrationTarget', affected, refresh_dependents: true, git_data: nil)
    after = read_unit(extractor, 'RefIntegrationCaller')
    expect(touched).to include('RefIntegrationCaller')
    expect(after.except('dependencies')).to eq(before.except('dependencies'))
    expect(after['dependencies']).to eq([expected_edge])
    expect(graph.node('RefIntegrationCaller', type: :poro)).to include(attributes)
    expect(graph.node('RefIntegrationCaller', type: :poro)[:file_path]).to eq(File.join(@root, 'app/models/caller.rb'))
    expect(extractor.instance_variable_get(:@incremental_written).keys).to eq(['RefIntegrationTarget'])
    expected_dependents = [{ 'type' => 'poro', 'identifier' => 'RefIntegrationCaller' }]
    expect(read_unit(extractor, 'RefIntegrationTarget')['dependents']).to eq(expected_dependents)
    expect(read_unit(previous, 'RefIntegrationCaller')).to eq(before)
  end

  it 'withdraws an edge and reverse entry when its target is deleted' do
    full
    File.unlink(File.join(@root, 'app/models/target.rb'))
    extractor = incremental
    affected = Set.new
    extractor.send(:remove_unit, 'RefIntegrationTarget', affected, type: :poro)
    extractor.send(:enrich_source_references_incremental, affected)
    expect(read_unit(extractor, 'RefIntegrationCaller')['dependencies']).to eq([])
    expect(extractor.dependency_graph.dependents_of('RefIntegrationTarget')).to eq([])
    expect(extractor.dependency_graph.to_h[:reverse_via]).not_to have_key('RefIntegrationTarget')
  end

  it 'requires a full rebuild before mutating old or corrupt source-reference baselines' do
    previous = full
    cache_path = previous.payload_dir.join(Woods::SourceReferences::Cache::FILE_NAME)
    File.unlink(cache_path)
    token = Woods::Generation.new(output_dir: @output).current.token
    expect { incremental }.to raise_error(Woods::SourceReferences::RebuildRequired, /full extraction/)
    expect(Woods::Generation.new(output_dir: @output).current.token).to eq(token)
    File.write(cache_path, '[]')
    expect { incremental }.to raise_error(Woods::SourceReferences::RebuildRequired, /full extraction/)
  end

  it 'allows empty indexes to initialize a reference cache' do
    extractor = Woods::Extractor.new(output_dir: @output)
    extractor.send(:begin_source_inputs, 'incremental')
    extractor.send(:begin_payload!)
    extractor.send(:prepare_source_reference_baseline)
    extractor.send(:enrich_source_references_incremental, Set.new)
    cache = Woods::SourceReferences::Cache.read(extractor.payload_dir.join(Woods::SourceReferences::Cache::FILE_NAME))
    expect(cache).to eq('version' => 1, 'files' => {}, 'owners' => [])
  end

  it 'fails a capped final scan even when the listed changed paths are unrelated to references' do
    extractor = full
    manifest = double('Manifest', data: { 'errors' => [
                        { 'reason' => 'source_changed_during_extraction', 'path' => 'config/locales/other.yml' }
                      ] })
    expect { extractor.send(:verify_source_reference_publication!, manifest) }
      .to raise_error(Woods::ExtractionError, /source changed/)
  end

  it 'allows legacy provenance unknown markers without mistaking them for current scan failures' do
    extractor = full
    manifest = double('Manifest', data: { 'errors' => [
                        { 'reason' => 'missing_or_incompatible_source_baseline' }
                      ] })
    expect { extractor.send(:verify_source_reference_publication!, manifest) }.not_to raise_error
  end

  it 'refuses a source change after analysis and preserves the published graph/cache generation' do
    previous = full
    token = Woods::Generation.new(output_dir: @output).current.token
    old_cache = File.binread(previous.payload_dir.join(Woods::SourceReferences::Cache::FILE_NAME))
    extractor = incremental
    extractor.send(:enrich_source_references_incremental, Set.new)
    write_source('caller', 'class RefIntegrationCaller; def changed; end; end')
    expect(extractor.send(:publish_generation, 'incremental')).to be_nil
    expect { extractor.raise_on_publication_failure! }.to raise_error(Woods::ExtractionError, /source.*changed/i)
    expect(Woods::Generation.new(output_dir: @output).current.token).to eq(token)
    expect(File.binread(previous.payload_dir.join(Woods::SourceReferences::Cache::FILE_NAME))).to eq(old_cache)
  end
end
