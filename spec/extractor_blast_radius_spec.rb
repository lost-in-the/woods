# frozen_string_literal: true

require 'spec_helper'
require 'pathname'
require 'tmpdir'
require 'fileutils'
require 'woods'
require 'woods/extractor'

# The blast radius an incremental run re-extracts, over a dependency chain
# ChainD -> ChainC -> ChainB -> ChainA (each unit depends on the next one
# named, so ChainA is the leaf everything reaches).
#
# Nothing here asserts anything about flows, pruning or publication: the
# subject is exactly which units `extract_changed` hands to
# `re_extract_unit` when one file changes.
RSpec.describe Woods::Extractor, 'incremental blast radius' do
  let(:tmpdir) { Dir.mktmpdir('woods_blast_radius') }
  let(:rails_root) { Pathname.new(tmpdir) }
  let(:logger) do
    instance_double(Logger, info: nil, warn: nil, error: nil, debug: nil)
  end

  let(:extractor) { described_class.new(output_dir: File.join(tmpdir, 'output')) }

  # ChainA's file is the one that changes.
  let(:changed_path) { 'app/models/chain_a.rb' }

  before do
    stub_const('Rails', double('Rails'))
    allow(Rails).to receive(:root).and_return(rails_root)
    allow(Rails).to receive(:logger).and_return(logger)
    allow(Rails).to receive(:version).and_return('8.0.0')
    @original_config = Woods.configuration
    Woods.configuration = Woods::Configuration.new

    register_chain
    stub_incremental_run
  end

  after do
    Woods.configuration = @original_config
    FileUtils.rm_rf(tmpdir)
  end

  # ChainD depends on ChainC depends on ChainB depends on ChainA.
  def register_chain
    graph = extractor.dependency_graph
    [%w[ChainD ChainC], %w[ChainC ChainB], %w[ChainB ChainA], ['ChainA', nil]].each do |identifier, target|
      unit = Woods::ExtractedUnit.new(
        type: :model,
        identifier: identifier,
        file_path: rails_root.join("app/models/#{identifier.gsub(/([a-z])([A-Z])/, '\1_\2').downcase}.rb").to_s
      )
      unit.dependencies = target ? [{ type: :model, target: target, via: :belongs_to }] : []
      graph.register(unit)
    end
  end

  # Everything past the blast radius is stubbed out: the run is not the
  # subject, the set of identifiers it re-extracts is.
  def stub_incremental_run
    %i[safe_eager_load! finalize_incremental_unit_json regenerate_type_index
       write_dependency_graph write_incremental_graph_analysis refresh_incremental_flows
       write_manifest write_structural_summary publish_generation].each do |phase|
      allow(extractor).to receive(phase)
    end
    %i[reconcile_class_based_types rerun_whole_app_extractors reannotate_packages
       prune_vanished_units].each do |phase|
      allow(extractor).to receive(phase).and_return(Set.new)
    end
    allow(extractor).to receive(:reconcile_changed_paths).and_return(Set.new(['ChainA']))
    allow(extractor).to receive(:re_extract_unit) { |unit_id, **| unit_id }
  end

  # The identifiers `extract_changed` re-extracted beyond the changed file's
  # own units.
  def re_extracted
    identifiers = []
    allow(extractor).to receive(:re_extract_unit) do |unit_id, **|
      identifiers << unit_id
      unit_id
    end
    extractor.extract_changed([changed_path])
    identifiers.sort
  end

  it 'walks the whole transitive dependent closure of the changed file' do
    expect(re_extracted).to eq(%w[ChainB ChainC ChainD])
  end

  it 'reports every unit in the closure as touched' do
    expect(extractor.extract_changed([changed_path]).sort).to eq(%w[ChainA ChainB ChainC ChainD])
  end
end
