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

    context 'with unit metadata' do
      let(:unit_metadata) do
        {
          'User' => {
            'type' => 'model',
            'metadata' => {
              'primary_key' => 'id',
              'columns' => [
                { 'name' => 'id', 'type' => 'bigint', 'null' => false },
                { 'name' => 'account_id', 'type' => 'bigint', 'null' => false },
                { 'name' => 'name', 'type' => 'character varying(255)', 'null' => false },
                { 'name' => 'email', 'type' => 'character varying(255)', 'null' => true }
              ],
              'associations' => [
                { 'name' => 'account', 'macro' => 'belongs_to', 'foreign_key' => 'account_id' }
              ]
            }
          },
          'UsersController' => {
            'type' => 'controller',
            'metadata' => {
              'actions' => %w[index show create update destroy]
            }
          },
          'UserService' => {
            'type' => 'service',
            'metadata' => {}
          }
        }
      end

      let(:forward_edges) do
        { 'User' => %w[Post Comment], 'UsersController' => ['User'], 'UserService' => ['User'] }
      end

      let(:reverse_edges) do
        { 'User' => Set.new(%w[UsersController UserService]), 'Post' => Set.new(['User']), 'Comment' => Set.new(['User']) }
      end

      subject do
        described_class.new(
          nodes: nodes,
          positions: positions,
          pagerank: pagerank,
          analysis: analysis,
          unit_metadata: unit_metadata,
          forward_edges: forward_edges,
          reverse_edges: reverse_edges
        )
      end

      it 'includes columns array on model nodes' do
        user_node = subject.build.find { |n| n['id'] == 'User' }
        columns = user_node['data']['columns']

        expect(columns).to be_an(Array)
        expect(columns.size).to eq(4)
        expect(columns.first).to include('name' => 'id', 'type' => 'bigint', 'primary' => true, 'nullable' => false)
      end

      it 'marks foreign key columns' do
        user_node = subject.build.find { |n| n['id'] == 'User' }
        fk_col = user_node['data']['columns'].find { |c| c['name'] == 'account_id' }
        expect(fk_col['foreign']).to be true
      end

      it 'marks nullable columns' do
        user_node = subject.build.find { |n| n['id'] == 'User' }
        email_col = user_node['data']['columns'].find { |c| c['name'] == 'email' }
        expect(email_col['nullable']).to be true
      end

      it 'includes attributes array on controller nodes' do
        controller_node = subject.build.find { |n| n['id'] == 'UsersController' }
        expect(controller_node['data']['attributes']).to eq(%w[index show create update destroy])
      end

      it 'includes file path as attributes fallback for service nodes' do
        service_node = subject.build.find { |n| n['id'] == 'UserService' }
        expect(service_node['data']['attributes']).to eq(['app/services/user_service.rb'])
      end

      it 'does not include columns on non-model nodes' do
        controller_node = subject.build.find { |n| n['id'] == 'UsersController' }
        expect(controller_node['data']).not_to have_key('columns')
      end

      it 'includes dependencyCount from forward edges' do
        user_node = subject.build.find { |n| n['id'] == 'User' }
        expect(user_node['data']['dependencyCount']).to eq(2)
      end

      it 'includes dependentCount from reverse edges' do
        user_node = subject.build.find { |n| n['id'] == 'User' }
        expect(user_node['data']['dependentCount']).to eq(2)
      end

      it 'defaults counts to 0 when no edges exist' do
        service_node = subject.build.find { |n| n['id'] == 'UserService' }
        expect(service_node['data']['dependentCount']).to eq(0)
      end
    end
  end
end
