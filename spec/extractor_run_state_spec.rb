# frozen_string_literal: true

require 'spec_helper'
require 'woods/extractor'

# Executable copy of the table in docs/EXTRACTOR_RUN_STATE.md. A reused
# Extractor must not carry per-run state from one entry point into the next.
RSpec.describe 'Extractor run state across reused entry points' do
  include_context 'isolated Woods runtime'

  around do |example|
    Dir.mktmpdir('woods-run-state') do |root|
      @root = Pathname.new(root)
      example.run
    end
  end

  shared_resets = {
    failed_consumers: :set, source_reference_refreshed: :set, source_reference_paths: :set,
    source_reference_occurrences: :hash, source_reference_baseline: :hash,
    publication_error: :scalar, payload_generation: :scalar, payload_dir: :scalar, git_capture: :scalar
  }.freeze

  full_resets = shared_resets.merge(
    results: :hash, extractors: :hash, package_resolver: :scalar, incremental_extractors: :hash,
    source_collector: :scalar, persisted_index_stats: :hash, graph_sha: :scalar, flow_failures: :array,
    symlinked_root: :scalar, symlinked_dirs: :hash
  ).freeze

  incremental_resets = shared_resets.merge(
    results: :hash, dependents_dirty: :set, incremental_written: :hash, retained_units: :set,
    changed_source_paths: :set, reference_additions: :hash,
    library_replacement_touched: :set, identity_claims: :hash, flow_scope: :set,
    flow_changed_units: :set, previous_flow_index_entries: :hash, incremental_extractors: :hash,
    source_collector: :scalar,
    hybrid_discovery_keys: :set, active_record_names: :set, package_resolver: :scalar,
    persisted_index_stats: :hash, graph_sha: :scalar, flow_failures: :array,
    symlinked_root: :scalar, symlinked_dirs: :hash
  ).freeze

  let(:sentinel) { '__stale_from_previous_run__' }
  # Same-typed poison, so a run that fails to reset an ivar still executes.
  let(:poison_values) do
    { set: -> { Set[sentinel] }, hash: -> { { sentinel => sentinel } }, array: -> { [sentinel] },
      scalar: -> { sentinel } }
  end
  let(:logger) { double('Logger').as_null_object }
  let(:output) { @root.join('index') }
  let(:extractor) { Woods::Extractor.new(output_dir: output) }
  let(:unit) { Woods::ExtractedUnit.new(type: :rails_source, identifier: 'ActiveRecord::Base', file_path: nil) }
  let(:fake_extractor_class) do
    framework_unit = unit
    Class.new { define_method(:extract_all) { [framework_unit] } }
  end

  before do
    stub_const('Rails', double('Rails', root: @root, logger: logger, version: '8.0.0'))
    Woods.configuration.concurrent_extraction = false
    stub_const('Woods::Extractor::EXTRACTORS', { rails_source: fake_extractor_class })
    %i[setup_output_directory safe_eager_load! prepare_source_reference_baseline deduplicate_results
       resolve_dependents enrich_with_git_data normalize_file_paths write_dependency_graph
       write_graph_analysis write_manifest write_structural_summary capture_snapshot log_summary
       write_results enrich_source_references_full project_source_references_full
       enrich_doc_references_full enrich_source_references_incremental enrich_doc_references_incremental
       finalize_incremental_unit_json refresh_commit_table refresh_incremental_flows
       write_incremental_graph_analysis publish_generation withdraw_disabled_flows].each do |phase|
      allow(extractor).to receive(phase)
    end
    allow(extractor).to receive(:enrich_source_references_incremental).and_return(Set.new)
    allow(extractor).to receive(:enrich_doc_references_incremental).and_return(Set.new)
    allow(extractor).to receive(:finalize_incremental_unit_json).and_return(Set.new)
    allow(extractor).to receive(:skipped_files_report).and_return([{}, nil])
    allow(Woods::ModelNameCache).to receive(:reset!)
    allow(Woods::GraphAnalyzer).to receive(:new).and_return(double('GraphAnalyzer', analyze: {}))
  end

  def publish_baseline
    directory = Woods::PayloadStore.new(output).create(1)
    manifest = { woods_version: Woods::VERSION, total_units: 0, counts: {},
                 extraction_config: Woods.configuration.extraction_fingerprint }
    directory.join('manifest.json').write(JSON.generate(manifest))
    directory.join('dependency_graph.json').write(JSON.generate(nodes: {}, edges: {}, reverse: {}, file_map: {}))
    Woods::Generation.new(output_dir: output).bump!(reason: 'full', payload: Woods::PayloadStore.name_for(1))
  end

  def poison(resets)
    resets.each { |name, kind| extractor.instance_variable_set(:"@#{name}", poison_values.fetch(kind).call) }
  end

  def carried_over(resets)
    resets.keys.select do |name|
      extractor.instance_variable_get(:"@#{name}").to_s.include?(sentinel) ||
        Array(extractor.instance_variable_get(:"@#{name}")).flatten.include?(sentinel)
    end
  end

  steps = {
    'full' => [:extract_all, [], full_resets],
    'incremental' => [:extract_changed, [['app/models/post.rb']], incremental_resets],
    'refresh' => [:refresh, [:rails_source], incremental_resets]
  }

  it 'resets every per-run ivar at each entry point of a full, incremental, refresh, full sequence' do
    sequence = [['full', steps['full']], ['incremental', steps['incremental']],
                ['refresh', steps['refresh']], ['full again', steps['full']]]

    sequence.each do |label, (entry_point, args, resets)|
      publish_baseline if label == 'incremental' && !Woods::Generation.new(output_dir: output).current.payload
      poison(resets)
      extractor.public_send(entry_point, *args)

      expect(carried_over(resets)).to eq([]), "#{label}: carried over #{carried_over(resets).inspect}"
    end
  end
end
