# frozen_string_literal: true

require 'spec_helper'
require 'set'
require 'woods/svelte_flow/edge_builder'

RSpec.describe Woods::SvelteFlow::EdgeBuilder do
  let(:edges) do
    { 'User' => %w[Post Comment], 'Post' => ['Comment'], 'Comment' => [] }
  end

  let(:valid_node_ids) { Set.new(%w[User Post Comment]) }

  subject do
    described_class.new(edges: edges, valid_node_ids: valid_node_ids)
  end

  describe '#build' do
    let(:result) { subject.build }

    it 'returns an array of Svelte Flow edge objects' do
      expect(result).to be_an(Array)
      expect(result.size).to eq(3) # User->Post, User->Comment, Post->Comment
    end

    it 'generates unique edge IDs' do
      ids = result.map { |e| e['id'] }
      expect(ids.uniq.size).to eq(ids.size)
    end

    it 'includes source and target references' do
      edge = result.find { |e| e['source'] == 'User' && e['target'] == 'Post' }
      expect(edge).not_to be_nil
      expect(edge['id']).to eq('e-User-Post')
    end

    it 'sets default edge type' do
      expect(result.first['type']).to eq('default')
    end

    it 'includes relationship data' do
      expect(result.first['data']['relationship']).to eq('dependency')
    end

    it 'skips edges to nodes not in valid_node_ids' do
      builder = described_class.new(
        edges: { 'A' => %w[B C] },
        valid_node_ids: Set.new(%w[A B])
      )
      result = builder.build
      targets = result.map { |e| e['target'] }
      expect(targets).not_to include('C')
    end

    it 'skips edges from nodes not in valid_node_ids' do
      builder = described_class.new(
        edges: { 'X' => ['Y'] },
        valid_node_ids: Set.new(['Y'])
      )
      expect(builder.build).to be_empty
    end

    it 'marks cycle edges' do
      cycle_edges = Set.new([%w[User Post]])
      builder = described_class.new(
        edges: edges,
        valid_node_ids: valid_node_ids,
        cycle_edges: cycle_edges
      )
      result = builder.build
      cycle_edge = result.find { |e| e['source'] == 'User' && e['target'] == 'Post' }

      expect(cycle_edge['data']['isCycle']).to be true
      expect(cycle_edge['animated']).to be true
    end

    it 'does not mark non-cycle edges as cycles' do
      builder = described_class.new(
        edges: edges,
        valid_node_ids: valid_node_ids,
        cycle_edges: Set.new
      )
      result = builder.build
      expect(result.all? { |e| e['data']['isCycle'] == false }).to be true
    end
  end

  describe '.flow_edges' do
    it 'returns empty array for empty steps' do
      expect(described_class.flow_edges([])).to eq([])
    end

    it 'creates sequential edges between flow steps' do
      steps = [
        { unit: 'Controller' },
        { unit: 'Service' },
        { unit: 'Model' }
      ]
      edges = described_class.flow_edges(steps)

      expect(edges.size).to eq(2)
      expect(edges[0]['source']).to eq('Controller')
      expect(edges[0]['target']).to eq('Service')
      expect(edges[1]['source']).to eq('Service')
      expect(edges[1]['target']).to eq('Model')
    end

    it 'uses smoothstep type for flow edges' do
      steps = [{ unit: 'A' }, { unit: 'B' }]
      edges = described_class.flow_edges(steps)

      expect(edges.first['type']).to eq('smoothstep')
    end

    it 'sets flow_step relationship' do
      steps = [{ unit: 'A' }, { unit: 'B' }]
      edges = described_class.flow_edges(steps)

      expect(edges.first['data']['relationship']).to eq('flow_step')
    end

    it 'skips self-referencing steps' do
      steps = [{ unit: 'A' }, { unit: 'A' }, { unit: 'B' }]
      edges = described_class.flow_edges(steps)

      expect(edges.size).to eq(1)
      expect(edges.first['source']).to eq('A')
      expect(edges.first['target']).to eq('B')
    end

    it 'deduplicates edges' do
      steps = [{ unit: 'A' }, { unit: 'B' }, { unit: 'A' }, { unit: 'B' }]
      edges = described_class.flow_edges(steps)

      ids = edges.map { |e| e['id'] }
      expect(ids.uniq.size).to eq(ids.size)
    end
  end

  describe '.boundary_edges' do
    let(:valid_ids) { Set.new(%w[A B C]) }

    it 'returns empty array for empty input' do
      expect(described_class.boundary_edges([], valid_node_ids: valid_ids)).to eq([])
    end

    it 'creates animated straight edges for boundaries' do
      boundaries = [{ from: 'A', to: 'B', via: 'dependency' }]
      result = described_class.boundary_edges(boundaries, valid_node_ids: valid_ids)

      expect(result.size).to eq(1)
      expect(result.first['type']).to eq('straight')
      expect(result.first['animated']).to be true
      expect(result.first['data']['relationship']).to eq('boundary')
    end

    it 'skips edges with invalid node IDs' do
      boundaries = [{ from: 'A', to: 'MISSING', via: 'dependency' }]
      result = described_class.boundary_edges(boundaries, valid_node_ids: valid_ids)

      expect(result).to be_empty
    end
  end
end
