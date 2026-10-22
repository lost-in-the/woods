# frozen_string_literal: true

require 'spec_helper'
require 'woods/impact/flows'

RSpec.describe Woods::Impact::Flows do
  let(:artifacts) { instance_double(Woods::Impact::Artifacts) }
  let(:options) { Woods::Impact::Options.new }
  let(:identity) { %w[Shared service] }
  let(:document) do
    { 'entry_point' => 'ItemsController#show', 'route' => { 'verb' => 'GET', 'path' => '/items' },
      'steps' => [{ 'unit' => 'Shared', 'type' => 'service', 'operations' => [] }] }
  end

  def compute
    described_class.new(artifacts, generation: 4, endpoint: 'to', options: options).call([identity])
  end

  before do
    allow(artifacts).to receive(:read).with('flows/by_unit.json')
                                      .and_return('Shared' => { 'model' => ['Wrong#index'],
                                                                'service' => ['ItemsController#show'] })
    allow(artifacts).to receive(:read).with('flows/flow_index.json')
                                      .and_return('ItemsController#show' => 'flows/ItemsController_show.json')
    allow(artifacts).to receive(:read).with('flows/ItemsController_show.json').and_return(document)
  end

  it 'uses W13 actual-type memberships and validates retained documents, with route and provenance' do
    result = compute
    expect(result['flows']).to include(include('entry_point' => 'ItemsController#show', 'generation' => 4,
                                               'changed_steps' => [{ 'identifier' => 'Shared', 'type' => 'service' }],
                                               'route' => { 'verb' => 'GET', 'path' => '/items' }))
    expect(result['coverage']).to eq('expanded_membership')
    expect(result['unknowns']).to include(include('kind' => 'expanded_membership_only'))
  end

  it 'refuses inverse membership without a matching actual typed document step' do
    document['steps'].first['type'] = 'model'
    result = compute
    expect(result['flows']).to eq([])
    expect(result['unknowns']).to include(include('kind' => 'invalid_flow_document'))
  end

  it 'does not treat unit membership as proof that a method call expanded, including nested calls' do
    document['steps'].first['operations'] = [
      { 'type' => 'conditional', 'then_ops' => [{ 'type' => 'call', 'target' => 'Shared', 'method' => 'other' }] }
    ]
    expect(compute['unknowns']).to include(include('kind' => 'unproven_call_expansion', 'method' => 'other'))
  end

  it 'marks missing legacy inverse as unavailable, without assembling source against another generation' do
    allow(artifacts).to receive(:read).with('flows/by_unit.json').and_raise(Errno::ENOENT)
    expect(compute).to include('flows' => [], 'coverage' => 'unavailable')
  end

  it 'bounds flow operation work and reports truncation' do
    allow(options).to receive(:to_h).and_return(Woods::Impact::Options.new(max_flow_operations: 1).to_h)
    document['steps'].first['operations'] = [{ 'type' => 'call' }, { 'type' => 'async', 'target' => 'Missing' }]
    result = compute
    expect(result['unknowns']).to include(include('kind' => 'flow_operation_budget'))
    expect(result['unknowns']).to include(include('kind' => 'receiverless_call'))
    expect(result['flows'].size).to eq(1)
    expect(result['coverage']).to eq('partial')
  end
end
