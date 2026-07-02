# frozen_string_literal: true

require 'spec_helper'
require 'woods/dependency_graph'
require 'woods/graph_analyzer'
require 'woods/svelte_flow/transformer'
require 'woods/svelte_flow/subgraph_scoper'

RSpec.describe Woods::SvelteFlow::SubgraphScoper do
  let(:graph) do
    dep_graph = Woods::DependencyGraph.new
    register(dep_graph, 'Order', :model, [{ target: 'Account', via: :belongs_to },
                                          { target: 'Invoice', via: :code_reference }])
    register(dep_graph, 'Account', :model, [])
    register(dep_graph, 'Invoice', :model, [])
    register(dep_graph, 'OrdersController', :controller, [{ target: 'Order', via: :code_reference }])
    dep_graph
  end

  let(:analyzer) { Woods::GraphAnalyzer.new(graph) }
  let(:transformer) { Woods::SvelteFlow::Transformer.new(graph: graph, analyzer: analyzer) }
  subject(:scoper) { described_class.new(transformer) }

  def register(dep_graph, identifier, type, deps)
    unit = instance_double('Woods::ExtractedUnit', identifier: identifier, type: type,
                                                   file_path: "app/#{identifier}.rb", namespace: nil,
                                                   dependencies: deps)
    dep_graph.register(unit)
  end

  def ids(payload)
    payload['nodes'].map { |n| n['id'] }
  end

  it 'renders exactly the seed set at depth 0' do
    payload = scoper.payload(seeds: %w[Order Account], depth: 0)
    expect(ids(payload)).to contain_exactly('Order', 'Account')
  end

  it 'includes an edge between two seeds, labeled with its via' do
    payload = scoper.payload(seeds: %w[Order Account], depth: 0)
    edge = payload['edges'].find { |e| e['source'] == 'Order' && e['target'] == 'Account' }
    expect(edge['data']['via']).to eq('belongs_to')
  end

  it 'expands forward and reverse neighbors at depth 1' do
    payload = scoper.payload(seeds: 'Order', depth: 1)
    expect(ids(payload)).to contain_exactly('Order', 'Account', 'Invoice', 'OrdersController')
  end

  it 'restricts expansion to the via relationship when filtered' do
    payload = scoper.payload(seeds: 'Order', depth: 1, via_set: Set[:belongs_to])
    expect(ids(payload)).to contain_exactly('Order', 'Account')
  end

  it 'accepts a single string seed as well as a collection' do
    expect(ids(scoper.payload(seeds: 'Account', depth: 0))).to contain_exactly('Account')
  end

  it 'reports the highest-pagerank node across the whole graph' do
    payload = scoper.payload(seeds: %w[Order], depth: 0)
    expect(payload).to have_key('highest_pagerank')
  end

  context 'with association metadata' do
    let(:unit_metadata) do
      {
        'Order' => {
          'type' => 'model',
          'metadata' => {
            'primary_key' => 'id',
            'associations' => [{ 'type' => 'belongs_to', 'target' => 'Account', 'foreign_key' => 'account_id' }]
          }
        },
        'Account' => { 'type' => 'model', 'metadata' => { 'primary_key' => 'id' } }
      }
    end

    let(:transformer) do
      Woods::SvelteFlow::Transformer.new(graph: graph, analyzer: analyzer, unit_metadata: unit_metadata)
    end

    def association_edges(payload)
      payload['edges'].select { |e| e['type'] == 'association' }
    end

    it 'emits model relationships as association edges with column handles' do
      edge = association_edges(scoper.payload(seeds: %w[Order Account], depth: 0)).first
      expect(edge['source']).to eq('Order')
      expect(edge['target']).to eq('Account')
      expect(edge['data']['via']).to eq('belongs_to')
      expect(edge['data']['foreignKey']).to eq('account_id')
      expect(edge['data']['sourceHandle']).to eq('Order-account_id')
      expect(edge['data']['targetHandle']).to eq('Account-id')
    end

    it 'does not also emit a generic edge for the association pair' do
      payload = scoper.payload(seeds: %w[Order Account], depth: 0)
      generic = payload['edges'].select do |e|
        e['type'] == 'default' && [e['source'], e['target']].sort == %w[Account Order]
      end
      expect(generic).to be_empty
    end

    it 'keeps generic edges for pairs without association metadata' do
      payload = scoper.payload(seeds: %w[Order Invoice], depth: 0)
      pair = payload['edges'].map { |e| [e['source'], e['target'], e['type']] }
      expect(pair).to include(%w[Order Invoice default])
    end

    it 'scopes association edges to the visited set' do
      payload = scoper.payload(seeds: %w[Order], depth: 0)
      expect(association_edges(payload)).to be_empty
    end

    it 'applies the via filter to association edges' do
      payload = scoper.payload(seeds: %w[Order Account], depth: 0, via_set: Set[:code_reference])
      expect(association_edges(payload)).to be_empty
    end
  end
end
