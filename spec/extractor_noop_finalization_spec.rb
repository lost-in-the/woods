# frozen_string_literal: true

require 'spec_helper'
require 'pathname'
require 'tmpdir'
require 'fileutils'
require 'json'
require 'digest'
require 'woods'
require 'woods/extractor'

# Pins staged no-op behavior and legacy flat fallback publication order.
RSpec.describe Woods::Extractor, 'payload-only no-op finalization' do
  include_context 'isolated Woods runtime'

  around do |example|
    Dir.mktmpdir('woods-noop-finalizer') do |directory|
      @root = Pathname.new(directory)
      example.run
    end
  end

  let(:output) { @root.join('index') }
  let(:extractor) { described_class.new(output_dir: output) }
  let(:events) { [] }
  let(:phases) { [] }
  let(:coverage) { nil }
  let(:existing_coverage) { nil }
  let(:report) { { 'total' => 0, 'counts' => {}, 'files' => [] } }

  def atomic_json(path, value)
    FileUtils.mkdir_p(path.dirname)
    Woods::AtomicFile.write(path, JSON.generate(value), durable: false)
  end

  def library_unit
    fragments = %W[a\n b\n]
    offset = 0
    records = fragments.each_with_index.map do |fragment, index|
      start = offset
      offset += fragment.bytesize
      record = {
        'file_path' => "lib/#{('a'.ord + index).chr}.rb", 'source_sha256' => Digest::SHA256.hexdigest(fragment),
        'facts' => {}, 'source_start_line' => 1, 'source_end_line' => 1,
        'published_start_byte' => start, 'published_end_byte' => offset,
        'published_start_line' => index + 1, 'published_end_line' => index + 1
      }
      record['git'] = { 'commit_count' => 1 } if index < coverage
      record
    end
    Woods::ExtractedUnit.new(type: :lib, identifier: 'RetainedLibrary', file_path: 'lib/a.rb').tap do |unit|
      unit.source_code = fragments.join
      unit.metadata = { source_contributors_version: 1, source_contributors: records }
    end
  end

  def seed_baseline
    retained = register_baseline_units
    directory = Woods::PayloadStore.new(output).create(1)
    write_baseline_artifacts(directory)
    write_retained_library(directory, retained) if retained
    Woods::Generation.new(output_dir: output).bump!(reason: 'full', payload: Woods::PayloadStore.name_for(1))
    reset_payload_state
  end

  def register_baseline_units
    extractor.dependency_graph.register(Woods::ExtractedUnit.new(type: :model, identifier: 'Anchor', file_path: nil))
    return if coverage.nil?

    retained = library_unit
    extractor.dependency_graph.register(retained)
    unless existing_coverage.nil?
      extractor.dependency_graph.annotate(retained.identifier, type: :lib, git_sources: existing_coverage)
    end
    retained
  end

  def write_baseline_artifacts(directory)
    extractor.instance_variable_set(:@payload_dir, directory)
    extractor.instance_variable_set(:@payload_generation, 1)
    extractor.send(:write_dependency_graph)
    write_baseline_manifest(directory)
    atomic_json(directory.join('models/_index.json'), [{ identifier: 'Anchor', chunk_count: 0 }])
    atomic_json(directory.join('skipped_files.json'), report)
  end

  def write_baseline_manifest(directory)
    atomic_json(directory.join('manifest.json'), woods_version: Woods::VERSION, extracted_at: 'baseline-time',
                                                 counts: { models: 1 }, total_units: 1, total_chunks: 0,
                                                 extraction_config: Woods.configuration.extraction_fingerprint)
  end

  def write_retained_library(directory, retained)
    filename = extractor.send(:collision_safe_filename, retained.identifier)
    atomic_json(directory.join('libs', filename), retained.to_h)
    atomic_json(directory.join('libs/_index.json'), [{ identifier: retained.identifier, chunk_count: 0 }])
  end

  def reset_payload_state
    extractor.instance_variable_set(:@payload_dir, nil)
    extractor.instance_variable_set(:@payload_generation, nil)
    extractor.instance_variable_set(:@graph_sha, nil)
  end

  def open_stage
    extractor.send(:begin_payload!, strict: true)
    extractor.instance_variable_set(:@graph_sha, nil)
  end

  def marker
    Woods::Generation.new(output_dir: output).current
  end

  def published_directory
    marker.payload ? output.join(marker.payload) : output
  end

  def published_bytes
    directory = published_directory
    files = Dir.glob(directory.join('**/*').to_s).select { |file| File.file?(file) }.sort
    content = files.each_with_object({}) do |file, bytes|
      relative = Pathname.new(file).relative_path_from(directory).to_s
      next if directory == output && relative.start_with?('payloads/')

      bytes[relative] = File.binread(file)
    end
    content['generation pointer'] = File.binread(output.join(Woods::Generation::FILENAME))
    content
  end

  def finalize(touched = Set.new)
    extractor.send(:finalize_incremental_run, touched)
  end

  def use_flat_fallback
    activate_flat_baseline
    allow_payload_creation_failure
    open_stage
    expect(extractor.instance_variable_get(:@payload_dir)).to be_nil
  end

  def activate_flat_baseline
    # Copy a complete active payload before opting into strict-flat fallback;
    # never merely clear @payload_dir while a payload marker stays published.
    published_directory.children.each { |entry| FileUtils.cp_r(entry, output.join(entry.basename)) }
    Woods::Generation.new(output_dir: output).bump!(reason: 'legacy', payload: nil)
  end

  def allow_payload_creation_failure
    store = extractor.instance_variable_get(:@payload_store)
    allow(store).to receive(:create).and_raise(Errno::ENOSPC, 'fixture payload unavailable')
    allow(extractor).to receive(:flat_fallback_allowed?).and_return(true)
  end

  before do
    stub_const('Rails', double('Rails', root: @root, logger: double('Logger').as_null_object, version: '8.1.0'))
    Woods.configuration.precompute_flows = false
    Woods.configuration.enable_snapshots = false
    Woods.configuration.pretty_json = false
    allow(Woods::AtomicFile).to receive(:sync_directory_tree).and_return(:syncfs)
    seed_baseline
    @current_report = report
    @published_report = report
    @commit_result = nil
    allow(extractor).to receive(:skipped_files_report) {
      events << :report
      [@current_report, @published_report]
    }
    allow(extractor).to receive(:refresh_commit_table) {
      events << :table
      @commit_result
    }
    %i[backfill_git_source_counts write_dependency_graph write_incremental_graph_analysis
       refresh_incremental_flows write_manifest write_structural_summary publish_generation].each do |name|
      allow(extractor).to receive(name).and_wrap_original do |method, *arguments, **keywords|
        events << name
        method.call(*arguments, **keywords)
      end
    end
    allow(extractor).to receive(:profile_phase).and_wrap_original do |method, name, &block|
      phases << name
      method.call(name, &block)
    end
    allow(Woods::AtomicFile).to receive(:write).and_wrap_original do |method, path, content, **options|
      if @fail_graph_write && Pathname.new(path).basename.to_s == 'dependency_graph.json'
        raise IOError, 'fixture graph write failure'
      end

      method.call(path, content, **options)
    end
  end

  it 'leaves every published artifact and pointer byte-identical on a payload-backed no-op' do
    before = published_bytes
    open_stage

    finalize

    expect(published_bytes).to eq(before)
    expect(events).to include(:backfill_git_source_counts, :report, :table)
    expect(events).not_to include(:write_manifest, :publish_generation)
  end

  it 'avoids graph serialization and ranking for an abandoned staged no-op', :noop_optimization do
    before = published_bytes
    open_stage
    expect(extractor.dependency_graph).not_to receive(:pagerank)
    expect(extractor).not_to receive(:json_serialize)

    finalize

    expect(events).not_to include(:write_dependency_graph, :write_incremental_graph_analysis)
    expect(published_bytes).to eq(before)
  end

  it 'does not expose a graph-write-only failure from an abandoned stage', :noop_optimization do
    before = published_bytes
    open_stage
    @fail_graph_write = true

    expect { finalize }.not_to raise_error

    expect(published_bytes).to eq(before)
  end

  it 'does not treat a missing previous skipped report as a new publication trigger' do
    @published_report = nil
    before = published_bytes
    open_stage

    finalize

    expect(published_bytes).to eq(before)
    expect(events).not_to include(:publish_generation)
  end

  [1, 0].each do |count|
    context "with #{count} retained library sources carrying facts" do
      let(:coverage) { count }

      it 'backfills missing coverage before report/table decisions without publishing the migration alone' do
        before = published_bytes
        open_stage
        allow(extractor).to receive(:refresh_commit_table) do
          events << :table
          expect(extractor.dependency_graph.node('RetainedLibrary', type: :lib)[:git_sources]).to eq(count)
          nil
        end

        finalize

        expect(events.index(:backfill_git_source_counts)).to be < events.index(:report)
        expect(events.index(:backfill_git_source_counts)).to be < events.index(:table)
        expect(published_bytes).to eq(before)
      end

      it 'persists the migrated coverage in the graph/hash/analysis on the next real publication' do
        open_stage

        finalize(Set['Anchor'])

        graph_path = published_directory.join('dependency_graph.json')
        graph = Woods::DependencyGraph.from_h(JSON.parse(Woods::AtomicFile.read(graph_path)))
        expect(graph.node('RetainedLibrary', type: :lib)[:git_sources]).to eq(count)
        analysis = JSON.parse(Woods::AtomicFile.read(published_directory.join('graph_analysis.json')))
        expect(analysis['graph_sha']).to eq(Digest::SHA256.file(graph_path).hexdigest)
        expect(marker.number).to eq(2)
      end
    end
  end

  context 'with explicit retained coverage already present' do
    let(:coverage) { 0 }
    let(:existing_coverage) { 7 }

    it 'does not overwrite an authoritative present coverage value during no-op migration' do
      open_stage

      finalize

      expect(extractor.dependency_graph.node('RetainedLibrary', type: :lib)[:git_sources]).to eq(7)
      expect(marker.number).to eq(1)
    end
  end

  [nil, :written, :withdrawn].each do |commit_result|
    it "writes one coherent graph before analysis when #{commit_result || :touched_unit} requires publication" do
      open_stage
      @commit_result = commit_result
      touched = commit_result ? Set.new : Set['Anchor']

      finalize(touched)

      expect(events.count(:write_dependency_graph)).to eq(1)
      if commit_result
        expect(events.index(:table)).to be < events.index(:write_dependency_graph)
      else
        expect(events.index(:write_dependency_graph)).to be < events.index(:report)
        expect(events.index(:write_dependency_graph)).to be < events.index(:table)
      end
      expect(events.index(:write_dependency_graph)).to be < events.index(:write_incremental_graph_analysis)
      expect(events.index(:write_incremental_graph_analysis)).to be < events.index(:write_manifest)
      expect(marker.number).to eq(2)
      graph = published_directory.join('dependency_graph.json')
      analysis = JSON.parse(Woods::AtomicFile.read(published_directory.join('graph_analysis.json')))
      expect(analysis['graph_sha']).to eq(Digest::SHA256.file(graph).hexdigest)
    end
  end

  it 'still publishes a report-only change while no unit is touched' do
    open_stage
    @current_report = { 'total' => 1, 'counts' => { 'parse_error' => 1 },
                        'files' => [{ 'path' => 'lib/broken.rb', 'reason' => 'parse_error' }] }

    finalize

    expect(marker.number).to eq(2)
    expect(Woods::SkippedFiles.read(published_directory)).to eq(@current_report)
    expect(events.count(:write_dependency_graph)).to eq(1)
    expect(events.index(:table)).to be < events.index(:write_dependency_graph)
  end

  it 'still publishes real disabled-flow withdrawal while no unit is touched' do
    open_stage
    atomic_json(extractor.send(:payload_dir).join('flows/flow_index.json'), {})

    finalize

    expect(marker.number).to eq(2)
    expect(published_directory.join('flows')).not_to exist
    expect(events.count(:write_dependency_graph)).to eq(1)
    expect(events.index(:write_dependency_graph)).to be < events.index(:report)
    expect(events.index(:write_dependency_graph)).to be < events.index(:table)
  end

  it 'does not advance the pointer or mutate the previous payload after a required graph-write failure' do
    before = published_bytes
    open_stage
    @fail_graph_write = true

    expect { finalize(Set['Anchor']) }.to raise_error(IOError, 'fixture graph write failure')

    expect(published_bytes).to eq(before)
    expect(events).not_to include(:report, :table, :write_incremental_graph_analysis,
                                  :write_manifest, :publish_generation)
  end

  it 'does not hide a backfill failure or run later publication decisions' do
    before = published_bytes
    open_stage
    allow(extractor).to receive(:backfill_git_source_counts).and_raise(IOError, 'fixture backfill failure')

    expect { finalize }.to raise_error(IOError, 'fixture backfill failure')

    expect(published_bytes).to eq(before)
    expect(events).not_to include(:report, :table, :write_manifest, :publish_generation)
  end

  it 'keeps the original graph-before-report/table order for an actual legacy flat fallback no-op' do
    use_flat_fallback
    before = published_bytes
    events.clear

    finalize

    expect(events.count(:write_dependency_graph)).to eq(1)
    expect(events.index(:write_dependency_graph)).to be < events.index(:report)
    expect(events.index(:write_dependency_graph)).to be < events.index(:table)
    expect(published_bytes).to eq(before)
  end

  it 'retains flat graph-write error precedence ahead of report and table reads' do
    use_flat_fallback
    before = published_bytes
    events.clear
    @fail_graph_write = true

    expect { finalize }.to raise_error(IOError, 'fixture graph write failure')

    expect(events).not_to include(:report, :table, :write_manifest, :publish_generation)
    expect(published_bytes).to eq(before)
  end

  it 'refuses flat fallback over a payload-born baseline even when the fallback flag is enabled' do
    before = published_bytes
    store = extractor.instance_variable_get(:@payload_store)
    allow(store).to receive(:create).and_raise(Errno::ENOSPC, 'fixture payload unavailable')
    allow(extractor).to receive(:flat_fallback_allowed?).and_return(true)

    expect { open_stage }.to raise_error(Woods::ExtractionError, /rather than the flat output root/)

    expect(published_bytes).to eq(before)
  end

  it 'keeps the settled captured revision authoritative in a HEAD-only publication' do
    open_stage
    captured = 'a' * 40
    extractor.instance_variable_set(:@git_capture_head, captured)
    extractor.instance_variable_set(:@git_capture_branch, 'captured-branch')
    extractor.instance_variable_set(:@git_capture_resolved, true)
    allow(extractor).to receive(:git_availability).and_return(available: true)
    expect(Woods::GitProvenance).not_to receive(:new)
    allow(extractor).to receive(:refresh_commit_table) do
      events << :table
      atomic_json(extractor.send(:payload_dir).join(Woods::GitCommitTable::FILENAME), 'head' => captured)
      :written
    end

    finalize

    manifest = JSON.parse(Woods::AtomicFile.read(published_directory.join('manifest.json')))
    table = JSON.parse(Woods::AtomicFile.read(published_directory.join(Woods::GitCommitTable::FILENAME)))
    expect(manifest.values_at('git_sha', 'git_branch')).to eq([captured, 'captured-branch'])
    expect(manifest.fetch('git_enrichment').fetch('head_sha')).to eq(captured)
    expect(table.fetch('head')).to eq(captured)
    expect(marker.number).to eq(2)
  end

  it 'preserves the baseline phase order when touched units already require publication' do
    open_stage
    phases.clear

    finalize(Set['Anchor'])

    expect(phases.take(6)).to eq(['graph write', 'skipped files', 'commit table',
                                  'graph analysis', 'flows', 'manifest and summary'])
  end

  it 'profiles only eager coverage and publication decisions for a staged no-op', :noop_optimization do
    open_stage

    finalize

    expect(phases).to eq(['git coverage backfill', 'skipped files', 'commit table'])
  end
end
