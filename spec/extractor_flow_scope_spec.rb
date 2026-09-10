# frozen_string_literal: true

require 'spec_helper'
require 'pathname'
require 'tmpdir'
require 'fileutils'
require 'json'
require 'woods'
require 'woods/extractor'

# Which controllers an incremental run reassembles flows for.
#
# `FlowAssembler` expands a controller to `FlowPrecomputer::DEFAULT_MAX_DEPTH`,
# so a controller further than that from everything the run changed cannot
# have a different flow document. It still loses `metadata[:flow_paths]` when
# it is re-extracted, so it carries its annotation forward from the previous
# generation's index instead of paying for the assembly.
RSpec.describe Woods::Extractor, 'incremental flow scope' do
  let(:tmpdir) { Dir.mktmpdir('woods_flow_scope') }
  let(:rails_root) { Pathname.new(tmpdir) }
  let(:logger) do
    instance_double(Logger, info: nil, warn: nil, error: nil, debug: nil)
  end

  let(:extractor) { described_class.new(output_dir: File.join(tmpdir, 'output')) }
  let(:precomputer) { instance_double(Woods::FlowPrecomputer) }
  let(:recompute_calls) { [] }

  # ModelLeaf is the file that changes. NearController reaches it in two
  # hops, FarController in five.
  let(:chain) do
    [
      %w[ServiceA ModelLeaf],
      %w[ServiceB ServiceA],
      %w[ServiceC ServiceB],
      %w[ServiceD ServiceC],
      %w[NearController ServiceA],
      %w[FarController ServiceD]
    ]
  end

  before do
    stub_const('Rails', double('Rails'))
    allow(Rails).to receive(:root).and_return(rails_root)
    allow(Rails).to receive(:logger).and_return(logger)
    allow(Rails).to receive(:version).and_return('8.0.0')
    @original_config = Woods.configuration
    Woods.configuration = Woods::Configuration.new
    Woods.configuration.precompute_flows = true

    register_graph
    stub_precomputer
    stub_incremental_run
  end

  after do
    Woods.configuration = @original_config
    FileUtils.rm_rf(tmpdir)
  end

  def register_graph
    graph = extractor.dependency_graph
    register_unit(graph, 'ModelLeaf', :model, nil)
    chain.each do |identifier, target|
      type = identifier.end_with?('Controller') ? :controller : :service
      register_unit(graph, identifier, type, target)
    end
  end

  def register_unit(graph, identifier, type, target)
    unit = Woods::ExtractedUnit.new(
      type: type,
      identifier: identifier,
      file_path: rails_root.join("app/#{type}s/#{identifier.downcase}.rb").to_s
    )
    unit.dependencies = target ? [{ type: :service, target: target, via: :code_reference }] : []
    graph.register(unit)
  end

  def stub_precomputer
    allow(precomputer).to receive(:recompute_delta) do |touched_units:, **rest|
      recompute_calls << { recomputed: touched_units.map(&:identifier).sort, rest: rest }
      {}
    end
    allow(Woods::FlowPrecomputer).to receive(:new).and_return(precomputer)
  end

  # The flow refresh is the subject, so it runs for real; everything else
  # around it is stubbed. The payload fixture is written from
  # `reconcile_changed_paths` because that is the first hook that runs after
  # the payload directory exists.
  def stub_incremental_run
    %i[safe_eager_load! finalize_incremental_unit_json regenerate_type_index
       write_dependency_graph write_incremental_graph_analysis patch_flow_annotations
       sweep_orphaned_flow_files write_manifest write_structural_summary
       publish_generation].each do |phase|
      allow(extractor).to receive(phase)
    end
    %i[reconcile_class_based_types rerun_whole_app_extractors reannotate_packages
       prune_vanished_units].each do |phase|
      allow(extractor).to receive(phase).and_return(Set.new)
    end
    allow(extractor).to receive(:re_extract_unit) { |unit_id, **| unit_id }
    allow(extractor).to receive(:reconcile_changed_paths) do
      write_payload_fixture
      Set.new(['ModelLeaf'])
    end
  end

  # A previous generation holding both controllers and their flow documents.
  def write_payload_fixture
    payload = extractor.send(:payload_dir)
    controllers = payload.join('controllers')
    flows = payload.join('flows')
    FileUtils.mkdir_p(controllers)
    FileUtils.mkdir_p(flows)

    index = {}
    %w[NearController FarController].each do |identifier|
      payload_json = JSON.generate(
        'type' => 'controller',
        'identifier' => identifier,
        'file_path' => "app/controllers/#{identifier.downcase}.rb",
        'metadata' => { 'actions' => ['index'] }
      )
      File.write(controllers.join(extractor.send(:collision_safe_filename, identifier)), payload_json)
      index["#{identifier}#index"] = "flows/#{identifier}_index.json"
      File.write(flows.join("#{identifier}_index.json"), '{}')
    end
    File.write(flows.join('flow_index.json'), JSON.generate(index))
  end

  def run
    extractor.extract_changed(['app/models/modelleaf.rb'])
    recompute_calls.first
  end

  it 'reassembles the controller inside the flow assembly radius' do
    expect(run[:recomputed]).to eq(['NearController'])
  end

  it 'carries the controller outside the radius forward instead' do
    expect(run[:rest][:carried_identifiers]).to eq(['FarController'])
  end
end
