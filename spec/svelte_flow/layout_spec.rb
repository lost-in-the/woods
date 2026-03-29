# frozen_string_literal: true

require 'spec_helper'
require 'woods/svelte_flow/layout'

RSpec.describe Woods::SvelteFlow::Layout do
  describe '#compute' do
    it 'returns empty hash for empty graph' do
      layout = described_class.new(edges: {})
      expect(layout.compute).to eq({})
    end

    it 'assigns position to a single node' do
      layout = described_class.new(edges: { 'A' => [] })
      positions = layout.compute

      expect(positions).to have_key('A')
      expect(positions['A']).to include('x' => 0, 'y' => 0)
    end

    it 'places dependent nodes in later layers' do
      layout = described_class.new(edges: { 'A' => ['B'], 'B' => [] })
      positions = layout.compute

      expect(positions['A']['x']).to be < positions['B']['x']
    end

    it 'places nodes in the same layer at the same x coordinate' do
      layout = described_class.new(edges: { 'Root' => %w[A B], 'A' => [], 'B' => [] })
      positions = layout.compute

      expect(positions['A']['x']).to eq(positions['B']['x'])
    end

    it 'assigns unique positions to all nodes' do
      layout = described_class.new(edges: { 'A' => ['B'], 'B' => ['C'], 'C' => [] })
      positions = layout.compute

      position_pairs = positions.values.map { |p| [p['x'], p['y']] }
      expect(position_pairs.uniq.size).to eq(position_pairs.size)
    end

    it 'handles cyclic graphs without infinite loop' do
      layout = described_class.new(edges: { 'A' => ['B'], 'B' => ['A'] })
      positions = layout.compute

      expect(positions).to have_key('A')
      expect(positions).to have_key('B')
    end

    it 'uses PageRank for tiebreaking in cycles' do
      layout = described_class.new(
        edges: { 'A' => ['B'], 'B' => ['A'] },
        pagerank: { 'A' => 0.8, 'B' => 0.2 }
      )
      positions = layout.compute

      expect(positions).to have_key('A')
      expect(positions).to have_key('B')
    end

    it 'returns numeric x and y values' do
      layout = described_class.new(edges: { 'X' => [] })
      positions = layout.compute

      expect(positions['X']['x']).to be_a(Numeric)
      expect(positions['X']['y']).to be_a(Numeric)
    end
  end

  describe '.flow_positions' do
    it 'returns empty hash for empty steps' do
      expect(described_class.flow_positions([])).to eq({})
    end

    it 'assigns vertical positions for sequential steps' do
      steps = [
        { unit: 'Controller#create' },
        { unit: 'Service' },
        { unit: 'Model' }
      ]
      positions = described_class.flow_positions(steps)

      expect(positions['Controller#create']['y']).to eq(0)
      expect(positions['Service']['y']).to eq(150)
      expect(positions['Model']['y']).to eq(300)
    end

    it 'deduplicates repeated units' do
      steps = [
        { unit: 'A' },
        { unit: 'B' },
        { unit: 'A' }
      ]
      positions = described_class.flow_positions(steps)

      expect(positions.size).to eq(2)
      expect(positions['A']['y']).to eq(0) # first occurrence
    end

    it 'handles string keys' do
      steps = [{ 'unit' => 'Foo' }]
      positions = described_class.flow_positions(steps)

      expect(positions).to have_key('Foo')
    end
  end

  describe '.cluster_positions' do
    it 'returns empty hash for empty clusters' do
      expect(described_class.cluster_positions([])).to eq({})
    end

    it 'assigns positions for cluster members' do
      clusters = [
        { members: %w[A B], name: 'Group1' }
      ]
      positions = described_class.cluster_positions(
        clusters,
        edges: { 'A' => ['B'], 'B' => [] }
      )

      expect(positions).to have_key('A')
      expect(positions).to have_key('B')
    end

    it 'offsets clusters in a grid layout' do
      clusters = [
        { members: ['A'], name: 'C1' },
        { members: ['B'], name: 'C2' }
      ]
      positions = described_class.cluster_positions(
        clusters,
        edges: { 'A' => [], 'B' => [] }
      )

      # Different clusters should have different base positions
      expect(positions['A']).not_to eq(positions['B'])
    end
  end
end
