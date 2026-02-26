# frozen_string_literal: true

require 'spec_helper'
require 'json'

RSpec.describe CodebaseIndex::DependencyGraph do
  let(:graph) { described_class.new }

  # Helper to create a minimal ExtractedUnit-like object
  def make_unit(type:, identifier:, file_path: nil, dependencies: [])
    unit = CodebaseIndex::ExtractedUnit.new(
      type: type,
      identifier: identifier,
      file_path: file_path || "/app/#{identifier.underscore}.rb"
    )
    unit.dependencies = dependencies
    unit
  end

  describe '#register' do
    it 'adds a node to the graph' do
      graph.register(make_unit(type: :model, identifier: 'User'))

      expect(graph.units_of_type(:model)).to include('User')
    end

    it 'does not add duplicate entries to type_index on re-registration' do
      unit = make_unit(type: :model, identifier: 'User')

      graph.register(unit)
      graph.register(unit)
      graph.register(unit)

      expect(graph.units_of_type(:model).count('User')).to eq(1)
    end

    it 'builds reverse edges' do
      user_unit = make_unit(type: :model, identifier: 'User')
      order_unit = make_unit(
        type: :model,
        identifier: 'Order',
        dependencies: [{ type: :model, target: 'User' }]
      )

      graph.register(user_unit)
      graph.register(order_unit)

      expect(graph.dependents_of('User')).to include('Order')
      expect(graph.dependencies_of('Order')).to include('User')
    end
  end

  describe '#affected_by' do
    before do
      graph.register(make_unit(type: :model, identifier: 'User', file_path: 'app/models/user.rb'))
      graph.register(make_unit(
                       type: :service, identifier: 'UserService',
                       file_path: 'app/services/user_service.rb',
                       dependencies: [{ type: :model, target: 'User' }]
                     ))
      graph.register(make_unit(
                       type: :controller, identifier: 'UsersController',
                       file_path: 'app/controllers/users_controller.rb',
                       dependencies: [{ type: :service, target: 'UserService' }]
                     ))
    end

    it 'returns directly changed units' do
      affected = graph.affected_by(['app/models/user.rb'])
      expect(affected).to include('User')
    end

    it 'returns transitively affected units' do
      affected = graph.affected_by(['app/models/user.rb'])
      expect(affected).to include('UserService')
      expect(affected).to include('UsersController')
    end

    it 'returns empty for unrelated files' do
      affected = graph.affected_by(['app/models/product.rb'])
      expect(affected).to be_empty
    end

    it 'respects max_depth' do
      affected = graph.affected_by(['app/models/user.rb'], max_depth: 1)
      expect(affected).to include('User')
      expect(affected).to include('UserService')
      expect(affected).not_to include('UsersController')
    end
  end

  describe '#pagerank' do
    it 'returns empty hash for empty graph' do
      expect(graph.pagerank).to eq({})
    end

    it 'assigns higher scores to highly-depended-upon nodes' do
      # User is depended upon by Order, UserService, and UsersController
      graph.register(make_unit(type: :model, identifier: 'User'))
      graph.register(make_unit(type: :model, identifier: 'Order',
                               dependencies: [{ type: :model, target: 'User' }]))
      graph.register(make_unit(type: :service, identifier: 'UserService',
                               dependencies: [{ type: :model, target: 'User' }]))
      graph.register(make_unit(type: :controller, identifier: 'UsersController',
                               dependencies: [{ type: :model, target: 'User' }]))
      graph.register(make_unit(type: :model, identifier: 'Product'))

      scores = graph.pagerank
      expect(scores['User']).to be > scores['Product']
    end

    it 'scores sum approximately to 1.0' do
      graph.register(make_unit(type: :model, identifier: 'A',
                               dependencies: [{ type: :model, target: 'B' }]))
      graph.register(make_unit(type: :model, identifier: 'B',
                               dependencies: [{ type: :model, target: 'C' }]))
      graph.register(make_unit(type: :model, identifier: 'C'))

      total = graph.pagerank.values.sum
      expect(total).to be_within(0.01).of(1.0)
    end
  end

  describe '#node_exists?' do
    before do
      graph.register(make_unit(type: :model, identifier: 'User'))
      graph.register(make_unit(type: :service, identifier: 'Order::Update'))
    end

    it 'returns true for a registered node' do
      expect(graph.node_exists?('User')).to be true
    end

    it 'returns false for an unknown identifier' do
      expect(graph.node_exists?('NonExistent')).to be false
    end

    it 'returns true for a namespaced node by full identifier' do
      expect(graph.node_exists?('Order::Update')).to be true
    end

    it 'returns false for a partial identifier that is not an exact match' do
      expect(graph.node_exists?('Update')).to be false
    end
  end

  describe '#find_node_by_suffix' do
    before do
      graph.register(make_unit(type: :service, identifier: 'Order::Update'))
      graph.register(make_unit(type: :service, identifier: 'User::Update'))
      graph.register(make_unit(type: :model, identifier: 'Product'))
    end

    it 'returns the matching node identifier when suffix matches' do
      result = graph.find_node_by_suffix('Update')
      expect(['Order::Update', 'User::Update']).to include(result)
    end

    it 'returns nil when no node matches the suffix' do
      expect(graph.find_node_by_suffix('NonExistent')).to be_nil
    end

    it 'returns nil for an exact-match identifier (suffix requires :: prefix)' do
      expect(graph.find_node_by_suffix('Product')).to be_nil
    end

    it 'returns the first match when multiple nodes share a suffix' do
      result = graph.find_node_by_suffix('Update')
      expect(result).not_to be_nil
      expect(result).to end_with('::Update')
    end
  end

  describe 'JSON round-trip' do
    before do
      graph.register(make_unit(type: :model, identifier: 'User',
                               file_path: 'app/models/user.rb'))
      graph.register(make_unit(type: :service, identifier: 'UserService',
                               file_path: 'app/services/user_service.rb',
                               dependencies: [{ type: :model, target: 'User' }]))
    end

    it 'preserves graph structure through JSON serialization' do
      json = JSON.generate(graph.to_h)
      restored = described_class.from_h(JSON.parse(json))

      expect(restored.dependencies_of('UserService')).to include('User')
      expect(restored.dependents_of('User')).to include('UserService')
      expect(restored.units_of_type(:model)).to include('User')
      expect(restored.units_of_type(:service)).to include('UserService')
    end

    it 'normalizes node value keys to symbols after JSON round-trip' do
      json = JSON.generate(graph.to_h)
      restored = described_class.from_h(JSON.parse(json))

      node = restored.to_h[:nodes]['User']
      expect(node[:type]).to eq(:model)
      expect(node[:file_path]).to eq('app/models/user.rb')
    end

    it 'normalizes type_index keys to symbols after JSON round-trip' do
      json = JSON.generate(graph.to_h)
      restored = described_class.from_h(JSON.parse(json))

      expect(restored.units_of_type(:model)).to include('User')
      expect(restored.units_of_type(:service)).to include('UserService')
    end
  end
end
