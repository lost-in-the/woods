# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'json'
require 'woods/dependency_graph'
require 'woods/flow_precomputer'

# W-14 (woods#764): best-effort mode publishes the flows that assemble and
# records the actions that do not, instead of aborting the run.
RSpec.describe Woods::FlowPrecomputer do
  let(:output_dir) { Dir.mktmpdir('flow_precomputer_best_effort') }
  let(:graph) { Woods::DependencyGraph.new }
  let(:assembler) { instance_double(Woods::FlowAssembler) }

  after { FileUtils.remove_entry(output_dir) }

  before do
    allow(Woods::FlowAssembler).to receive(:new).and_return(assembler)
    allow(assembler).to receive(:assemble) do |entry_point, **|
      raise StandardError, "no route in #{output_dir}/config/routes.rb" if entry_point.end_with?('#broken')

      Woods::FlowDocument.new(entry_point: entry_point,
                              steps: [{ unit: entry_point, type: 'controller', operations: [] }])
    end
  end

  def controller(identifier, actions)
    Woods::ExtractedUnit.new(type: :controller, identifier: identifier,
                             file_path: "app/controllers/#{identifier.underscore}.rb").tap do |unit|
      unit.metadata = { actions: actions }
      graph.register(unit)
    end
  end

  def index
    JSON.parse(File.read(File.join(output_dir, 'flows', 'flow_index.json')))
  end

  def precomputer
    described_class.new(units: [controller('BadController', %w[ok broken])], graph: graph, output_dir: output_dir,
                        best_effort: true, root: output_dir)
  end

  it 'publishes the flows that assemble and records the action that does not' do
    subject = precomputer
    expect(subject.precompute).to eq('BadController#ok' => 'flows/BadController_ok.json')
    expect(index.keys).to eq(['BadController#ok'])
    expect(subject.failures.values).to eq(
      [{ 'entry_point' => 'BadController#broken', 'controller' => 'BadController', 'action' => 'broken',
         'reason' => 'flow_assembly_error', 'error' => 'StandardError: no route in config/routes.rb' }]
    )
    expect(File).not_to exist(File.join(output_dir, 'flows', 'BadController_broken.json'))
  end

  it 'keeps the fail-closed contract when best effort is off' do
    strict = described_class.new(units: [controller('BadController', %w[ok broken])], graph: graph,
                                 output_dir: output_dir)
    expect { strict.precompute }.to raise_error(Woods::ExtractionError, /BadController#broken: no route/)
  end

  it 'carries the failures of controllers a delta does not replace, and replaces the rest' do
    precomputer.precompute
    previous = [
      { 'entry_point' => 'OtherController#broken', 'controller' => 'OtherController', 'action' => 'broken',
        'reason' => 'flow_assembly_error', 'error' => 'StandardError: old' },
      { 'entry_point' => 'GoneController#show', 'controller' => 'GoneController', 'action' => 'show',
        'reason' => 'flow_assembly_error', 'error' => 'StandardError: old' }
    ]
    delta = described_class.new(units: [], graph: graph, output_dir: output_dir, best_effort: true)
    fixed = controller('BadController', %w[ok])
    delta.recompute_delta(touched_units: [fixed], removed_identifiers: ['GoneController'],
                          previous_failures: previous + precomputer.failures.values)
    expect(delta.failures.keys).to eq(['OtherController#broken'])
    expect(index.keys).to eq(['BadController#ok'])
  end
end
