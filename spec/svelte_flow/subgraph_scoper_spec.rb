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
end
