# frozen_string_literal: true

require 'spec_helper'
require 'woods/svelte_flow/node_builder'

RSpec.describe Woods::SvelteFlow::NodeBuilder do
  let(:nodes) do
    {
      'User' => { type: :model, file_path: 'app/models/user.rb', namespace: nil },
      'UsersController' => { type: :controller, file_path: 'app/controllers/users_controller.rb', namespace: nil },
      'UserService' => { type: :service, file_path: 'app/services/user_service.rb', namespace: nil }
    }
  end

  let(:positions) do
    {
      'User' => { 'x' => 0, 'y' => 0 },
      'UsersController' => { 'x' => 300, 'y' => 0 },
      'UserService' => { 'x' => 300, 'y' => 100 }
    }
  end

  let(:pagerank) do
    { 'User' => 0.05, 'UsersController' => 0.03, 'UserService' => 0.02 }
  end

  let(:analysis) do
    {
      hubs: [{ identifier: 'User', type: :model, dependent_count: 5, dependents: [] }],
      bridges: [{ identifier: 'UserService', type: :service, score: 3 }],
      orphans: ['UsersController']
    }
  end

  subject do
    described_class.new(
      nodes: nodes,
      positions: positions,
      pagerank: pagerank,
      analysis: analysis
    )
  end

  describe '#build' do
    let(:result) { subject.build }

    it 'returns an array of Svelte Flow node objects' do
      expect(result).to be_an(Array)
      expect(result.size).to eq(3)
    end

    it 'includes correct id for each node' do
      ids = result.map { |n| n['id'] }
      expect(ids).to contain_exactly('User', 'UsersController', 'UserService')
    end

    it 'maps unit types to Svelte Flow node types' do
      user_node = result.find { |n| n['id'] == 'User' }
      expect(user_node['type']).to eq('model')

      controller_node = result.find { |n| n['id'] == 'UsersController' }
      expect(controller_node['type']).to eq('controller')
    end

    it 'includes position data' do
      user_node = result.find { |n| n['id'] == 'User' }
      expect(user_node['position']).to eq({ 'x' => 0, 'y' => 0 })
    end

    it 'includes data with label and metadata' do
      user_node = result.find { |n| n['id'] == 'User' }
      data = user_node['data']

      expect(data['label']).to eq('User')
      expect(data['unitType']).to eq('model')
      expect(data['filePath']).to eq('app/models/user.rb')
      expect(data['pagerank']).to eq(0.05)
    end

    it 'marks hub nodes' do
      user_node = result.find { |n| n['id'] == 'User' }
      expect(user_node['data']['isHub']).to be true

      service_node = result.find { |n| n['id'] == 'UserService' }
      expect(service_node['data']['isHub']).to be false
    end

    it 'marks bridge nodes' do
      service_node = result.find { |n| n['id'] == 'UserService' }
      expect(service_node['data']['isBridge']).to be true
    end

    it 'marks orphan nodes' do
      controller_node = result.find { |n| n['id'] == 'UsersController' }
      expect(controller_node['data']['isOrphan']).to be true
    end

    it 'falls back to default type for unknown unit types' do
      builder = described_class.new(
        nodes: { 'Foo' => { type: :unknown_type, file_path: 'foo.rb', namespace: nil } },
        positions: { 'Foo' => { 'x' => 0, 'y' => 0 } }
      )
      result = builder.build
      expect(result.first['type']).to eq('default')
    end

    it 'provides default position when node has no position entry' do
      builder = described_class.new(
        nodes: { 'Bar' => { type: :model, file_path: 'bar.rb', namespace: nil } },
        positions: {}
      )
      result = builder.build
      expect(result.first['position']).to eq({ 'x' => 0, 'y' => 0 })
    end
  end
end
