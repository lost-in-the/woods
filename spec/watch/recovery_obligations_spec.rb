# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'woods/extractor'
require 'woods/watch/daemon'

RSpec.describe 'Watcher reconciliation obligations' do
  include_context 'isolated Woods runtime'

  around do |example|
    Dir.mktmpdir('woods-watch-recovery') do |root|
      @root = Pathname.new(root)
      @output = @root.join('index')
      example.run
    end
  end

  before do
    stub_const('Rails', double('Rails', root: @root, logger: double('Logger').as_null_object))
  end

  def generation
    Woods::Generation.new(output_dir: @output)
  end

  def publish_baseline
    extractor = Woods::Extractor.new(output_dir: @output)
    extractor.send(:begin_source_inputs, 'full')
    extractor.send(:begin_payload!)
    extractor.instance_variable_set(:@eager_load_complete, true)
    Woods::AtomicFile.write(extractor.payload_dir.join('manifest.json'), JSON.generate(counts: {}, total_units: 0))
    extractor.send(:publish_generation, 'full')
    extractor.raise_on_publication_failure!
  end

  def daemon_for(extractor, **options)
    Woods::Watch::Daemon.new(root: @root.to_s, output_dir: @output.to_s,
                             extractor_factory: -> { extractor }, debounce: 0,
                             reloader: double('Reloader', enabled?: true, reload!: true),
                             boot_snapshot: Woods::Watch::BootSnapshot.new(root: @root), **options)
  end

  def retry_pending(daemon)
    daemon.send(:retry_pending)
    thread = daemon.instance_variable_get(:@retry_thread)
    expect(thread&.join(5)).not_to be_nil
  end

  def status
    JSON.parse(Woods::AtomicFile.read(@output.join('watch_status.json')))
  end

  %i[extraction publication lock].each do |failure|
    it "retries deletion-only startup after #{failure} failure without inventing deleted paths" do
      publish_baseline
      Woods::AtomicFile.write(generation.payload_dir.join('dependency_graph.json'),
                              JSON.generate(file_map: { 'app/services/removed.rb' => ['Removed'] }))
      extractor = instance_spy(Woods::Extractor)
      allow(extractor).to receive(:extract_changed).and_return(['Removed'])
      if failure == :extraction
        allow(extractor).to receive(:extract_changed).and_raise(IOError, 'temporary source failure')
      end
      lock = double('Lock', acquire: failure != :lock, release: nil)
      daemon = daemon_for(extractor, lock: lock)

      daemon.send(:catch_up)

      expect(status['state']).to eq('degraded')
      expect(generation.current.number).to eq(1)
      allow(lock).to receive(:acquire).and_return(true)
      allow(extractor).to receive(:extract_changed) do |paths|
        expect(paths).to eq([])
        generation.bump!(reason: 'incremental', payload: generation.current.payload)
        ['Removed']
      end

      retry_pending(daemon)

      expect(status['state']).to eq('running')
      expect(generation.current.number).to eq(2)
      expect(daemon.send(:pending_empty?)).to be(true)
      attempts = failure == :lock ? 1 : 2
      expect(extractor).to have_received(:extract_changed).with([]).exactly(attempts).times
      daemon.send(:drain)
      expect(extractor).to have_received(:extract_changed).with([]).exactly(attempts).times
    end
  end

  it 'discharges deletion reconciliation after a successful no-op for a nominal graph path' do
    publish_baseline
    Woods::AtomicFile.write(generation.payload_dir.join('dependency_graph.json'),
                            JSON.generate(file_map: { 'app/models/schema_migration.rb' => ['SchemaMigration'] }))
    extractor = instance_spy(Woods::Extractor)
    allow(extractor).to receive(:extract_changed).and_raise(IOError, 'temporary source failure')
    daemon = daemon_for(extractor)
    daemon.send(:catch_up)
    allow(extractor).to receive(:extract_changed).and_return([])

    retry_pending(daemon)

    expect(status['state']).to eq('running')
    expect(generation.current.number).to eq(1)
    expect(daemon.send(:pending_empty?)).to be(true)
    daemon.send(:drain)
    expect(extractor).to have_received(:extract_changed).with([]).twice
  end

  it 'retains an empty-touch flow withdrawal event after publication failure and retries it' do
    publish_baseline
    previous = generation.payload_dir
    FileUtils.mkdir_p(previous.join('flows'))
    Woods::AtomicFile.write(previous.join('flows/old.json'), '{}')
    Woods.configuration.precompute_flows = false
    extractor = flow_withdrawal_extractor
    allow_any_instance_of(Woods::Generation).to receive(:bump!).and_raise(Errno::EACCES, 'temporary marker refusal')
    path = @root.join('config/locales/empty.yml')
    FileUtils.mkdir_p(path.dirname)
    File.write(path, '{}')
    daemon = daemon_for(extractor, catch_up: false)

    result = daemon.process([path.to_s])

    expect(result).to include(state: :degraded, generation: 1)
    expect(result[:reason]).to include('temporary marker refusal')
    expect(status['state']).to eq('degraded')
    expect(generation.payload_dir).to eq(previous)
    expect(previous.join('flows/old.json')).to exist
    expect(extractor.payload_dir.join('flows')).not_to exist
    expect(daemon.send(:pending_empty?)).to be(false)

    allow_any_instance_of(Woods::Generation).to receive(:bump!).and_call_original
    retry_pending(daemon)

    expect(status['state']).to eq('running')
    expect(generation.current.number).to eq(2)
    expect(generation.payload_dir.join('flows')).not_to exist
    expect(previous.join('flows/old.json')).to exist
    expect(daemon.send(:pending_empty?)).to be(true)
  end

  # Keep the real extract_changed/finalization/flow withdrawal/publication
  # boundary while isolating unrelated Rails extraction and graph phases.
  def flow_withdrawal_extractor
    Woods::Extractor.new(output_dir: @output).tap do |extractor|
      allow(extractor).to receive(:prepare_incremental_run) { extractor.send(:begin_payload!, strict: true) }
      allow(extractor.dependency_graph).to receive(:affected_by).and_return([])
      %i[hybrid_discovery_keys flow_scope_for reconcile_changed_paths reconcile_class_based_types reconcile_model_mixins
         rerun_whole_app_extractors reannotate_packages prune_vanished_units
         enrich_source_references_incremental].each do |name|
        allow(extractor).to receive(name).and_return(Set.new)
      end
      %i[finalize_incremental_unit_json write_dependency_graph write_incremental_graph_analysis
         refresh_incremental_flows write_manifest write_structural_summary sync_payload].each do |name|
        allow(extractor).to receive(name)
      end
    end
  end
end
