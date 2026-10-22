# frozen_string_literal: true

require 'spec_helper'
require 'woods/impact/propagation'

RSpec.describe Woods::Impact::Propagation do
  def units(*identities)
    identities.to_h { |id, type| [[id, type], { 'identifier' => id, 'type' => type }] }
  end

  def graph(reverse)
    { 'reverse_via' => reverse, 'pagerank' => { 'Caller' => 0.75 } }
  end

  def edge(id, type, via = 'code_reference', target_type = nil)
    { 'source' => id, 'source_type' => type, 'via' => via, 'type' => target_type }
  end

  def compute(graph_data, inventory, roots, **options)
    described_class.new(graph_data, inventory, generation: 4, endpoint: 'to',
                                               options: Woods::Impact::Options.new(**options)).call(roots)
  end

  it 'walks exact typed sources, records shortest generation-bound paths, and terminates cycles' do
    inventory = units(%w[Changed model], %w[Caller service], %w[Outer controller])
    data = graph('Changed' => [edge('Caller', 'service')], 'Caller' => [edge('Outer', 'controller')],
                 'Outer' => [edge('Caller', 'service')])
    result = compute(data, inventory, [%w[Changed model]], depth: 5)
    caller, outer = result.fetch('affected')
    expect(caller).to include('identifier' => 'Caller', 'type' => 'service', 'distance' => 1, 'weight' => 0.75)
    expect(outer).to include('identifier' => 'Outer', 'distance' => 2, 'generation' => 4, 'endpoint' => 'to')
    expect(outer.fetch('paths').first.fetch('edges').map { |item| item.dig('source', 'identifier') })
      .to eq(%w[Caller Outer])
  end

  it 'does not mix same-name types or invent a target type at a collision' do
    inventory = units(%w[Shared model], %w[Shared service], %w[Caller service])
    data = graph('Shared' => [edge('Caller', 'service')])
    result = compute(data, inventory, [%w[Shared model]])
    expect(result['affected']).to eq([])
    expect(result['unknowns']).to include(include('kind' => 'ambiguous_target', 'identifier' => 'Shared'))
    data['reverse_via']['Shared'].first['type'] = 'model'
    expect(compute(data, inventory, [%w[Shared model]])['affected'].map { |item| item['identifier'] }).to eq(['Caller'])
    expect(compute(data, inventory, [%w[Shared service]])['affected']).to eq([])
  end

  it 'does not override a conflicting target hint even for a unique identifier' do
    inventory = units(%w[Changed model], %w[Caller service])
    data = graph('Changed' => [edge('Caller', 'service', 'code_reference', 'service')])
    result = compute(data, inventory, [%w[Changed model]])
    expect(result['affected']).to eq([])
    expect(result['unknowns']).to include(include('kind' => 'conflicting_target_type'))
  end

  it 'does not treat a malformed false target hint as an absent type' do
    inventory = units(%w[Changed model], %w[Caller service])
    data = graph('Changed' => [edge('Caller', 'service', 'code_reference', false)])
    result = compute(data, inventory, [%w[Changed model]])
    expect(result['affected']).to eq([])
    expect(result['unknowns']).to include(include('kind' => 'conflicting_target_type'))
  end

  it 'filters traversal by actual types and via, with explicit finite budgets' do
    inventory = units(%w[Changed model], %w[Caller service], %w[Outer controller])
    data = graph('Changed' => [edge('Caller', 'service')], 'Caller' => [edge('Outer', 'controller')])
    expect(compute(data, inventory, [%w[Changed model]], types: ['controller'])['affected']).to eq([])
    expect(compute(data, inventory, [%w[Changed model]], via: ['render'])['affected']).to eq([])
    result = compute(data, inventory, [%w[Changed model]], max_nodes: 1)
    expect(result['unknowns']).to include(include('kind' => 'node_budget'))
    expect(result['coverage']).to eq('partial')
  end

  it 'retains separate witnesses for multiple changed roots deterministically' do
    inventory = units(%w[Alpha model], %w[Beta model], %w[Caller service])
    data = graph('Alpha' => [edge('Caller', 'service')], 'Beta' => [edge('Caller', 'service')])
    result = compute(data, inventory, [%w[Beta model], %w[Alpha model]])
    expect(result['affected'].first['paths'].map { |path| path.dig('root', 'identifier') }).to eq(%w[Alpha Beta])
    expect(result).to eq(compute(data, inventory, [%w[Alpha model], %w[Beta model]]))
  end

  it 'marks unavailable weights and unresolved typed sources instead of dropping evidence silently' do
    inventory = units(%w[Changed model], %w[Caller service], %w[Caller model])
    data = graph('Changed' => [edge('Caller', 'service'), edge('Missing', 'job')])
    result = compute(data, inventory, [%w[Changed model]])
    expect(result['affected'].first['weight']).to be_nil
    expect(result['unknowns']).to include(include('kind' => 'ambiguous_weight'), include('kind' => 'unresolved_source'))
  end

  it 'retains distinct unresolved source records and charges the edge budget before processing' do
    inventory = units(%w[Changed model])
    data = graph('Changed' => [edge('MissingOne', 'service'), edge('MissingTwo', 'job')])
    result = compute(data, inventory, [%w[Changed model]])
    expect(result['unknowns'].map { |item| item.dig('edge', 'source') }).to eq(%w[MissingOne MissingTwo])
    result = compute(data, inventory, [%w[Changed model]], max_edges: 1)
    expect(result['unknowns']).to include(include('kind' => 'edge_budget'))
    expect(result['unknowns']).not_to include(include('edge' => include('source' => 'MissingTwo')))
  end

  it 'rejects unsupported parameters instead of accepting misleading filters' do
    expect { Woods::Impact::Options.new(depth: -1) }.to raise_error(ArgumentError)
    expect { Woods::Impact::Options.new(max_edges: 0) }.to raise_error(ArgumentError)
    expect { Woods::Impact::Options.new(types: 'model') }.to raise_error(ArgumentError)
  end
end
