# frozen_string_literal: true

require 'spec_helper'
require 'woods/dependency_graph'
require 'woods/graph_analyzer'
require 'woods/svelte_flow/transformer'

RSpec.describe Woods::SvelteFlow::Transformer do
  let(:graph) do
    g = Woods::DependencyGraph.new
    # Register mock units
    register_unit(g, 'User', :model, 'app/models/user.rb', [{ target: 'Post' }])
    register_unit(g, 'Post', :model, 'app/models/post.rb', [{ target: 'Comment' }])
    register_unit(g, 'Comment', :model, 'app/models/comment.rb', [])
    register_unit(g, 'UsersController', :controller, 'app/controllers/users_controller.rb', [{ target: 'User' }])
    g
  end

  let(:analyzer) { Woods::GraphAnalyzer.new(graph) }
  subject { described_class.new(graph: graph, analyzer: analyzer) }

  describe '#dependency_graph_data' do
    let(:result) { subject.dependency_graph_data }

    it 'returns hash with nodes and edges keys' do
      expect(result).to have_key('nodes')
      expect(result).to have_key('edges')
    end

    it 'includes all graph nodes' do
      ids = result['nodes'].map { |n| n['id'] }
      expect(ids).to contain_exactly('User', 'Post', 'Comment', 'UsersController')
    end

    it 'includes edges between connected nodes' do
      edge_pairs = result['edges'].map { |e| [e['source'], e['target']] }
      expect(edge_pairs).to include(%w[User Post])
      expect(edge_pairs).to include(%w[Post Comment])
      expect(edge_pairs).to include(%w[UsersController User])
    end

    it 'includes node position data' do
      node = result['nodes'].first
      expect(node['position']).to have_key('x')
      expect(node['position']).to have_key('y')
    end

    it 'includes pagerank in node data' do
      node = result['nodes'].find { |n| n['id'] == 'User' }
      expect(node['data']['pagerank']).to be_a(Float)
    end

    it 'includes structural annotations' do
      node = result['nodes'].first
      expect(node['data']).to have_key('isHub')
      expect(node['data']).to have_key('isBridge')
      expect(node['data']).to have_key('isOrphan')
    end
  end

  describe '#flow_data' do
    let(:flow_doc) do
      {
        entry_point: 'UsersController#create',
        route: { verb: 'POST', path: '/users' },
        max_depth: 5,
        steps: [
          { unit: 'UsersController#create', type: 'controller', file_path: 'app/controllers/users_controller.rb',
            operations: [{ type: 'call', target: 'UserService', method: 'call', line: 10 }] },
          { unit: 'UserService', type: 'service', file_path: 'app/services/user_service.rb',
            operations: [{ type: 'call', target: 'User', method: 'create!', line: 5 }] }
        ]
      }
    end

    let(:result) { subject.flow_data(flow_doc) }

    it 'returns hash with nodes, edges, and metadata' do
      expect(result).to have_key('nodes')
      expect(result).to have_key('edges')
      expect(result).to have_key('metadata')
    end

    it 'creates flow_step typed nodes' do
      expect(result['nodes'].all? { |n| n['type'] == 'flow_step' }).to be true
    end

    it 'creates sequential flow edges' do
      expect(result['edges'].size).to eq(1)
      expect(result['edges'].first['source']).to eq('UsersController#create')
      expect(result['edges'].first['target']).to eq('UserService')
    end

    it 'uses smoothstep edge type for flows' do
      expect(result['edges'].first['type']).to eq('smoothstep')
    end

    it 'includes metadata about the flow' do
      expect(result['metadata']['entryPoint']).to eq('UsersController#create')
      expect(result['metadata']['route']).to eq({ verb: 'POST', path: '/users' })
    end

    it 'includes operation summaries in node data' do
      node = result['nodes'].first
      expect(node['data']['operations']).to be_an(Array)
      expect(node['data']['operationCount']).to eq(1)
    end

    it 'deduplicates nodes for repeated units' do
      doc = {
        entry_point: 'A',
        steps: [{ unit: 'A', type: 'x', operations: [] }, { unit: 'B', type: 'y', operations: [] },
                { unit: 'A', type: 'x', operations: [] }]
      }
      result = subject.flow_data(doc)
      ids = result['nodes'].map { |n| n['id'] }
      expect(ids.uniq.size).to eq(ids.size)
    end
  end

  describe '#domain_cluster_data' do
    let(:result) { subject.domain_cluster_data }

    it 'returns hash with nodes, edges, and clusters keys' do
      expect(result).to have_key('nodes')
      expect(result).to have_key('edges')
      expect(result).to have_key('clusters')
    end
  end

  describe '#full_export' do
    it 'returns combined data with all visualization types' do
      result = subject.full_export

      expect(result).to have_key('dependency_graph')
      expect(result).to have_key('domain_clusters')
      expect(result).to have_key('flows')
    end

    it 'includes flow documents when provided' do
      flow = {
        entry_point: 'TestController#index',
        steps: [{ unit: 'TestController#index', type: 'controller', operations: [] }]
      }
      result = subject.full_export(flow_documents: [flow])

      expect(result['flows']).to have_key('TestController#index')
    end
  end

  private

  def register_unit(graph, identifier, type, file_path, dependencies)
    unit = instance_double(
      'Woods::ExtractedUnit',
      identifier: identifier,
      type: type,
      file_path: file_path,
      namespace: nil,
      dependencies: dependencies
    )
    graph.register(unit)
  end
end
