# frozen_string_literal: true

require 'spec_helper'
require 'pathname'
require 'tmpdir'
require 'fileutils'
require 'woods'
require 'woods/extractor'

# Phase timing behind WOODS_PROFILE. The per-extractor lines already tell us
# how long extraction itself took; nothing said how the rest of a run splits
# between the graph load, the analysis, the flows and the publish.
RSpec.describe Woods::Extractor, 'phase profiling' do
  let(:tmpdir) { Dir.mktmpdir('woods_profile') }
  let(:rails_root) { Pathname.new(tmpdir) }
  let(:logged) { [] }
  let(:logger) do
    instance_double(Logger).tap do |log|
      allow(log).to receive(:info) { |message| logged << message.to_s }
      allow(log).to receive(:warn)
      allow(log).to receive(:error)
      allow(log).to receive(:debug)
    end
  end

  let(:extractor) { described_class.new(output_dir: File.join(tmpdir, 'output')) }

  before do
    stub_const('Rails', double('Rails'))
    allow(Rails).to receive(:root).and_return(rails_root)
    allow(Rails).to receive(:logger).and_return(logger)
    allow(Rails).to receive(:version).and_return('8.0.0')
    @original_config = Woods.configuration
    Woods.configuration = Woods::Configuration.new
    Woods.configuration.concurrent_extraction = false
    # The payload flush is real work against the real filesystem; the phase
    # line is what this spec is about, not the syscall.
    allow(Woods::AtomicFile).to receive(:sync_directory_tree).and_return(:syncfs)
  end

  after do
    Woods.configuration = @original_config
    FileUtils.rm_rf(tmpdir)
  end

  # Phase names, in the order the line is emitted.
  def profiled_phases
    logged.filter_map do |message|
      match = message.match(/\A\[Woods\] \[profile\] (.+) in \d+\.\d+s\z/)
      match && match[1]
    end
  end

  def stub_full_run
    Woods.configuration.precompute_flows = true
    %i[setup_output_directory safe_eager_load! extract_all_sequential precompute_flows
       deduplicate_results annotate_packages resolve_dependents enrich_with_git_data
       annotate_graph_with_git_data normalize_file_paths write_results
       sweep_orphaned_unit_files write_dependency_graph write_graph_analysis
       write_manifest write_structural_summary capture_snapshot
       log_summary].each do |phase|
      allow(extractor).to receive(phase)
    end
    allow(Woods::ModelNameCache).to receive(:reset!)
    allow(Woods::GraphAnalyzer).to receive(:new).and_return(double('GraphAnalyzer', analyze: {}))
  end

  def stub_incremental_run
    extractor.dependency_graph.register(
      Woods::ExtractedUnit.new(type: :model, identifier: 'BaselineAnchor', file_path: nil)
    )
    %i[safe_eager_load! finalize_incremental_unit_json regenerate_type_index
       write_dependency_graph write_incremental_graph_analysis refresh_incremental_flows
       write_manifest write_structural_summary].each do |phase|
      allow(extractor).to receive(phase)
    end
    %i[reconcile_class_based_types rerun_whole_app_extractors reannotate_packages
       prune_vanished_units].each do |phase|
      allow(extractor).to receive(phase).and_return(Set.new)
    end
    allow(extractor).to receive(:reconcile_changed_paths).and_return(Set.new(['User']))
  end

  context 'when WOODS_PROFILE is not set' do
    before { allow(ENV).to receive(:fetch).and_call_original }

    it 'logs no phase timing lines during a full extraction' do
      stub_full_run

      extractor.extract_all

      expect(profiled_phases).to be_empty
    end
  end

  context 'when WOODS_PROFILE=1' do
    around do |example|
      original = ENV.fetch('WOODS_PROFILE', nil)
      ENV['WOODS_PROFILE'] = '1'
      example.run
    ensure
      ENV['WOODS_PROFILE'] = original
    end

    it 'logs one timing line per full-extraction phase, in run order' do
      stub_full_run

      extractor.extract_all

      expect(profiled_phases).to eq(
        ['payload seed', 'eager load', 'extraction', 'graph analysis', 'write results',
         'flows', 'manifest and summary', 'payload sync', 'publish']
      )
    end

    it 'logs one timing line per incremental phase, in run order' do
      stub_incremental_run

      extractor.extract_changed(['app/models/user.rb'])

      expect(profiled_phases).to eq(
        ['payload seed', 'previous graph load', 'eager load', 'blast radius', 'flow radius',
         're-extraction', 'type index', 'graph analysis', 'flows', 'manifest and summary',
         'payload sync', 'publish']
      )
    end

    it 'returns the phase result unchanged' do
      expect(extractor.send(:profile_phase, 'anything') { :the_value }).to eq(:the_value)
    end
  end
end
