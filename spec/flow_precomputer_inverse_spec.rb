# frozen_string_literal: true

require 'spec_helper'
require 'woods/flow_precomputer'

RSpec.describe Woods::FlowPrecomputer, 'inverted flow index' do
  let(:output_dir) { Dir.mktmpdir('woods_inverse') }
  let(:graph) { Woods::DependencyGraph.new }
  let(:assembler) { instance_double(Woods::FlowAssembler) }
  let(:inverse_path) { File.join(output_dir, 'flows', 'by_unit.json') }

  before { allow(Woods::FlowAssembler).to receive(:new).and_return(assembler) }
  after { FileUtils.remove_entry(output_dir) }

  def controller(identifier, *actions)
    Woods::ExtractedUnit.new(type: :controller, identifier: identifier,
                             file_path: 'app/controllers/example.rb').tap do |unit|
      unit.metadata = { actions: actions }
    end
  end

  def flow(entry_point, *identities)
    steps = identities.map { |identifier, type| { unit: identifier, type: type, operations: [] } }
    Woods::FlowDocument.new(entry_point: entry_point, steps: steps)
  end

  def assemble(document)
    allow(assembler).to receive(:assemble).with(document.entry_point, max_depth: 3).and_return(document)
  end

  def precompute(*units)
    described_class.new(units: units, graph: graph, output_dir: output_dir).precompute
  end

  def delta(**args)
    described_class.new(units: [], graph: graph, output_dir: output_dir).recompute_delta(**args)
  end

  def inverse
    JSON.parse(Woods::AtomicFile.read(inverse_path))
  end

  it 'indexes actual typed steps, normalizes action suffixes, and excludes cycle sentinels and operation targets' do
    document = flow('ItemsController#show', ['ItemsController#show', 'controller'],
                    %w[Shared model], %w[Shared service], %w[Shared service], %w[Loop cycle])
    document.steps.first[:operations] << { type: 'call', target: 'Unexpanded' }
    assemble(document)

    precompute(controller('ItemsController', 'show'))

    expect(inverse).to eq(
      'ItemsController' => { 'controller' => ['ItemsController#show'] },
      'Shared' => { 'model' => ['ItemsController#show'], 'service' => ['ItemsController#show'] }
    )
  end

  it 'sorts keys and unique entry points deterministically across assembly order' do
    assemble(flow('ZController#show', %w[Zulu job], %w[Shared service]))
    assemble(flow('AController#show', %w[Alpha model], %w[Shared model], %w[Shared service], %w[Shared service]))
    precompute(controller('ZController', 'show'), controller('AController', 'show'))
    first = Woods::AtomicFile.read(inverse_path)

    precompute(controller('AController', 'show'), controller('ZController', 'show'))

    expect(Woods::AtomicFile.read(inverse_path)).to eq(first)
    expect(inverse).to eq(
      'Alpha' => { 'model' => ['AController#show'] },
      'Shared' => { 'model' => ['AController#show'], 'service' => ['AController#show', 'ZController#show'] },
      'Zulu' => { 'job' => ['ZController#show'] }
    )
  end

  it 'writes an empty index when there are no flows' do
    precompute
    expect(inverse).to eq({})
  end

  it 'replaces changed actions and removes deleted controllers while retaining untouched and carried memberships' do
    assemble(flow('ChangedController#old', %w[Old service], %w[Shared model]))
    assemble(flow('RemovedController#index', %w[Removed service]))
    assemble(flow('UntouchedController#index', %w[Shared service]))
    assemble(flow('CarriedController#index', %w[Shared service]))
    precompute(controller('ChangedController', 'old'), controller('RemovedController', 'index'),
               controller('UntouchedController', 'index'), controller('CarriedController', 'index'))
    untouched = File.join(output_dir, 'flows', 'UntouchedController_index.json')
    original = Woods::AtomicFile.read(untouched)
    allow(Woods::AtomicFile).to receive(:read).and_call_original
    expect(Woods::AtomicFile).not_to receive(:read).with(untouched)
    assemble(flow('ChangedController#new', %w[New job], %w[Shared model]))

    delta(touched_units: [controller('ChangedController', 'new')],
          removed_identifiers: ['RemovedController'], carried_identifiers: ['CarriedController'])

    expect(inverse).to eq(
      'New' => { 'job' => ['ChangedController#new'] },
      'Shared' => { 'model' => ['ChangedController#new'],
                    'service' => ['CarriedController#index', 'UntouchedController#index'] }
    )
    expect(File.binread(untouched)).to eq(original)
  end

  it 'matches a full recomputation after replacement and deletion' do
    assemble(flow('ChangedController#old', %w[Old service]))
    assemble(flow('RemovedController#index', %w[Removed service]))
    assemble(flow('UntouchedController#index', %w[Shared service]))
    precompute(controller('ChangedController', 'old'), controller('RemovedController', 'index'),
               controller('UntouchedController', 'index'))
    assemble(flow('ChangedController#new', %w[Shared model]))
    delta(touched_units: [controller('ChangedController', 'new')], removed_identifiers: ['RemovedController'])
    incremental = Woods::AtomicFile.read(inverse_path)

    precompute(controller('ChangedController', 'new'), controller('UntouchedController', 'index'))

    expect(Woods::AtomicFile.read(inverse_path)).to eq(incremental)
  end

  it 'rebuilds an older missing inverse from carried documents without reassembling them' do
    assemble(flow('CarriedController#index', %w[Café service]))
    precompute(controller('CarriedController', 'index'))
    expected = Woods::AtomicFile.read(inverse_path)
    FileUtils.rm_f(inverse_path)
    expect(assembler).not_to receive(:assemble)

    delta(touched_units: [], carried_identifiers: ['CarriedController'])

    expect(Woods::AtomicFile.read(inverse_path)).to eq(expected)
  end

  it 'does not read obsolete documents when upgrading an older generation' do
    assemble(flow('RemovedController#index', %w[Removed service]))
    precompute(controller('RemovedController', 'index'))
    FileUtils.rm_f(inverse_path)
    FileUtils.rm_f(File.join(output_dir, 'flows', 'RemovedController_index.json'))

    delta(touched_units: [], removed_identifiers: ['RemovedController'])

    expect(inverse).to eq({})
  end

  it 'fails closed when an older generation cannot reconstruct carried membership' do
    assemble(flow('CarriedController#index', %w[Shared service]))
    precompute(controller('CarriedController', 'index'))
    FileUtils.rm_f(inverse_path)
    File.write(File.join(output_dir, 'flows', 'CarriedController_index.json'), '{ invalid')

    expect { delta(touched_units: []) }.to raise_error(Woods::ExtractionError, /flow|inverse/)
    expect(File).not_to exist(inverse_path)
  end

  it 'fails closed for a corrupt existing inverse' do
    precompute
    File.write(inverse_path, '{ invalid')

    expect { delta(touched_units: []) }.to raise_error(Woods::ExtractionError, /by_unit/)
  end

  it 'rejects an older flow document for a different entry point' do
    assemble(flow('CarriedController#index', %w[Shared service]))
    precompute(controller('CarriedController', 'index'))
    FileUtils.rm_f(inverse_path)
    document = flow('OtherController#index', %w[Other service])
    File.write(File.join(output_dir, 'flows', 'CarriedController_index.json'), JSON.generate(document.to_h))

    expect { delta(touched_units: []) }.to raise_error(Woods::ExtractionError, /entry_point/)
    expect(File).not_to exist(inverse_path)
  end

  [
    { unit: 'Shared', type: 42 },
    { unit: '#action', type: 'service' }
  ].each do |invalid_step|
    it "rejects an older flow with an invalid typed step: #{invalid_step}" do
      assemble(flow('CarriedController#index', %w[Shared service]))
      precompute(controller('CarriedController', 'index'))
      FileUtils.rm_f(inverse_path)
      document = { entry_point: 'CarriedController#index', steps: [invalid_step] }
      File.write(File.join(output_dir, 'flows', 'CarriedController_index.json'), JSON.generate(document))

      expect { delta(touched_units: []) }.to raise_error(Woods::ExtractionError, /typed identity/)
      expect(File).not_to exist(inverse_path)
    end
  end

  it 'fails closed for a malformed existing inverse instead of publishing an empty lookup' do
    precompute
    File.write(inverse_path, JSON.generate('Shared' => ['WrongController#index']))

    expect { delta(touched_units: []) }.to raise_error(Woods::ExtractionError, /by_unit/)
  end

  it 'atomically replaces a seeded hardlink without changing the preceding generation' do
    precompute
    previous_path = File.join(output_dir, 'previous_by_unit.json')
    File.link(inverse_path, previous_path)
    assemble(flow('ItemsController#index', %w[Shared service]))

    delta(touched_units: [controller('ItemsController', 'index')])

    expect(JSON.parse(Woods::AtomicFile.read(previous_path))).to eq({})
    expect(inverse).to eq('Shared' => { 'service' => ['ItemsController#index'] })
  end
end
