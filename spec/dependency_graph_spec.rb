# frozen_string_literal: true

require 'spec_helper'
require 'json'

RSpec.describe Woods::DependencyGraph do
  let(:graph) { described_class.new }

  # Helper to create a minimal ExtractedUnit-like object
  def make_unit(type:, identifier:, file_path: nil, dependencies: [])
    unit = Woods::ExtractedUnit.new(
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

    it 'removes stale reverse edges when a unit is re-registered with different dependencies' do
      graph.register(make_unit(type: :model, identifier: 'User'))
      graph.register(make_unit(type: :model, identifier: 'Account'))

      order_v1 = make_unit(
        type: :model,
        identifier: 'Order',
        dependencies: [{ type: :model, target: 'User', via: :belongs_to }]
      )
      graph.register(order_v1)
      expect(graph.dependents_of('User')).to include('Order')

      # The Order source dropped its User dependency — incremental
      # re-extraction registers into the already-loaded graph.
      order_v2 = make_unit(
        type: :model,
        identifier: 'Order',
        dependencies: [{ type: :model, target: 'Account', via: :belongs_to }]
      )
      graph.register(order_v2)

      expect(graph.dependents_of('User')).not_to include('Order')
      expect(graph.dependents_of('User', via: :belongs_to)).not_to include('Order')
      expect(graph.dependents_of('Account')).to include('Order')
    end

    it 'updates the file map when a unit is re-registered under a new path' do
      graph.register(make_unit(type: :model, identifier: 'User', file_path: '/app/models/user.rb'))
      graph.register(
        make_unit(
          type: :model,
          identifier: 'Consumer',
          dependencies: [{ type: :model, target: 'User', via: :code_reference }]
        )
      )
      graph.register(make_unit(type: :model, identifier: 'User', file_path: '/app/models/core/user.rb'))

      expect(graph.affected_by(['/app/models/user.rb'])).to be_empty
      expect(graph.affected_by(['/app/models/core/user.rb'])).to contain_exactly('User', 'Consumer')
    end

    it 'cleans stale reverse edges when re-registering into a graph loaded from JSON' do
      order = make_unit(
        type: :model,
        identifier: 'Order',
        dependencies: [{ type: :model, target: 'User', via: :belongs_to }]
      )
      graph.register(make_unit(type: :model, identifier: 'User'))
      graph.register(order)

      loaded = described_class.from_h(JSON.parse(JSON.generate(graph.to_h)))
      order_v2 = make_unit(type: :model, identifier: 'Order', dependencies: [])
      loaded.register(order_v2)

      expect(loaded.dependents_of('User')).not_to include('Order')
    end
  end

  describe '#remove' do
    it 'removes the node, its edges, its file_map entry, and its type-index entry' do
      graph.register(make_unit(
                       type: :model, identifier: 'User', file_path: 'app/models/user.rb',
                       dependencies: [{ type: :model, target: 'Account' }]
                     ))

      graph.remove('User')

      expect(graph.node_exists?('User')).to be false
      expect(graph.tracks_file?('app/models/user.rb')).to be false
      expect(graph.units_of_type(:model)).not_to include('User')
      expect(graph.dependencies_of('User')).to be_empty
      expect(graph.dependents_of('Account')).not_to include('User')
    end

    it 'stops affected_by from returning the removed unit' do
      graph.register(make_unit(type: :model, identifier: 'User', file_path: 'app/models/user.rb'))
      graph.remove('User')

      expect(graph.affected_by(['app/models/user.rb'])).to be_empty
    end

    it 'keeps other units\' forward edges toward the removed identifier' do
      graph.register(make_unit(type: :model, identifier: 'User', file_path: 'app/models/user.rb'))
      graph.register(make_unit(
                       type: :service, identifier: 'UserService',
                       file_path: 'app/services/user_service.rb',
                       dependencies: [{ type: :model, target: 'User' }]
                     ))

      graph.remove('User')

      expect(graph.dependencies_of('UserService')).to include('User')
    end

    it 'is a no-op for identifiers that were never registered' do
      expect { graph.remove('Ghost') }.not_to raise_error
    end

    it 'survives a serialization round-trip' do
      graph.register(make_unit(type: :model, identifier: 'User', file_path: 'app/models/user.rb'))
      graph.remove('User')

      loaded = described_class.from_h(JSON.parse(JSON.generate(graph.to_h)))
      expect(loaded.node_exists?('User')).to be false
      expect(loaded.tracks_file?('app/models/user.rb')).to be false
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

  describe '#dependencies_of with via filter' do
    before do
      graph.register(make_unit(type: :model, identifier: 'User'))
      graph.register(make_unit(
                       type: :controller,
                       identifier: 'UsersController',
                       dependencies: [
                         { type: :model, target: 'User', via: :code_reference },
                         { type: :controller, target: 'ApplicationController', via: :include },
                         { type: :controller, target: 'PostsController', via: :redirect_to }
                       ]
                     ))
    end

    it 'returns all targets when via is nil' do
      deps = graph.dependencies_of('UsersController')
      expect(deps).to contain_exactly('User', 'ApplicationController', 'PostsController')
    end

    it 'filters by a single via type' do
      deps = graph.dependencies_of('UsersController', via: :redirect_to)
      expect(deps).to eq(['PostsController'])
    end

    it 'filters by multiple via types' do
      deps = graph.dependencies_of('UsersController', via: %i[code_reference redirect_to])
      expect(deps).to contain_exactly('User', 'PostsController')
    end

    it 'returns empty when no edges match the via filter' do
      deps = graph.dependencies_of('UsersController', via: :link_to)
      expect(deps).to be_empty
    end
  end

  describe '#dependents_of with via filter' do
    before do
      graph.register(make_unit(type: :model, identifier: 'User'))
      graph.register(make_unit(
                       type: :service, identifier: 'UserService',
                       dependencies: [{ type: :model, target: 'User', via: :code_reference }]
                     ))
      graph.register(make_unit(
                       type: :controller, identifier: 'UsersController',
                       dependencies: [{ type: :model, target: 'User', via: :link_to }]
                     ))
    end

    it 'returns all dependents when via is nil' do
      deps = graph.dependents_of('User')
      expect(deps).to contain_exactly('UserService', 'UsersController')
    end

    it 'filters dependents by via type' do
      deps = graph.dependents_of('User', via: :link_to)
      expect(deps).to eq(['UsersController'])
    end

    it 'returns empty when no dependents match the via filter' do
      deps = graph.dependents_of('User', via: :redirect_to)
      expect(deps).to be_empty
    end
  end

  describe '@edges shape' do
    it 'stores edges as hashes with target and via keys' do
      graph.register(make_unit(
                       type: :model, identifier: 'Order',
                       dependencies: [{ type: :model, target: 'User', via: :belongs_to }]
                     ))

      edges = graph.instance_variable_get(:@edges)
      expect(edges['Order']).to eq([{ target: 'User', via: :belongs_to }])
    end

    it 'stores nil via when dependency has no via key' do
      graph.register(make_unit(
                       type: :model, identifier: 'Order',
                       dependencies: [{ type: :model, target: 'User' }]
                     ))

      edges = graph.instance_variable_get(:@edges)
      expect(edges['Order']).to eq([{ target: 'User', via: nil }])
    end
  end

  describe 'Set-based internals' do
    it 'stores @reverse values as Sets' do
      graph.register(make_unit(type: :model, identifier: 'User'))
      graph.register(make_unit(type: :model, identifier: 'Order',
                               dependencies: [{ type: :model, target: 'User' }]))

      reverse = graph.instance_variable_get(:@reverse)
      expect(reverse['User']).to be_a(Set)
      expect(reverse['User']).to include('Order')
    end

    it 'stores @type_index values as Sets' do
      graph.register(make_unit(type: :model, identifier: 'User'))
      graph.register(make_unit(type: :model, identifier: 'Post'))

      type_index = graph.instance_variable_get(:@type_index)
      expect(type_index[:model]).to be_a(Set)
      expect(type_index[:model]).to contain_exactly('User', 'Post')
    end

    it 'deduplicates reverse entries on repeated registration' do
      user = make_unit(type: :model, identifier: 'User')
      order = make_unit(type: :model, identifier: 'Order',
                        dependencies: [{ type: :model, target: 'User' }])

      graph.register(user)
      graph.register(order)
      graph.register(order) # duplicate

      reverse = graph.instance_variable_get(:@reverse)
      expect(reverse['User'].size).to eq(1)
    end
  end

  describe '#to_h memoization' do
    before do
      graph.register(make_unit(type: :model, identifier: 'User'))
    end

    it 'returns equal but distinct objects on consecutive calls (dup protection)' do
      first = graph.to_h
      second = graph.to_h
      expect(first).to eq(second)
      expect(first).not_to equal(second)
    end

    it 'invalidates the cache when a new unit is registered' do
      first = graph.to_h
      graph.register(make_unit(type: :model, identifier: 'Post'))
      second = graph.to_h

      expect(second).not_to equal(first)
      expect(second[:stats][:node_count]).to eq(2)
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

    it 'restores @reverse as Sets after round-trip' do
      json = JSON.generate(graph.to_h)
      restored = described_class.from_h(JSON.parse(json))

      reverse = restored.instance_variable_get(:@reverse)
      expect(reverse['User']).to be_a(Set)
      expect(reverse['User']).to include('UserService')
    end

    it 'restores @type_index as Sets after round-trip' do
      json = JSON.generate(graph.to_h)
      restored = described_class.from_h(JSON.parse(json))

      type_index = restored.instance_variable_get(:@type_index)
      expect(type_index[:model]).to be_a(Set)
      expect(type_index[:service]).to be_a(Set)
    end

    it 'serializes @reverse Sets as arrays in to_h output' do
      serialized = graph.to_h
      expect(serialized[:reverse]['User']).to be_a(Array)
      expect(serialized[:reverse]['User']).to include('UserService')
    end

    it 'serializes @type_index Sets as arrays in to_h output' do
      serialized = graph.to_h
      expect(serialized[:type_index][:model]).to be_a(Array)
      expect(serialized[:type_index][:service]).to be_a(Array)
    end

    it 'preserves via metadata through JSON round-trip' do
      via_graph = described_class.new
      via_graph.register(make_unit(
                           type: :model, identifier: 'User',
                           file_path: 'app/models/user.rb'
                         ))
      via_graph.register(make_unit(
                           type: :controller, identifier: 'UsersController',
                           file_path: 'app/controllers/users_controller.rb',
                           dependencies: [
                             { type: :model, target: 'User', via: :code_reference },
                             { type: :controller, target: 'PostsController', via: :redirect_to }
                           ]
                         ))

      json = JSON.generate(via_graph.to_h)
      restored = described_class.from_h(JSON.parse(json))

      expect(restored.dependencies_of('UsersController')).to contain_exactly('User', 'PostsController')
      expect(restored.dependencies_of('UsersController', via: :redirect_to)).to eq(['PostsController'])
      expect(restored.dependencies_of('UsersController', via: :code_reference)).to eq(['User'])
    end

    it 'handles old format (bare string edges) in from_h' do
      old_data = {
        'nodes' => {
          'User' => { 'type' => 'model', 'file_path' => 'app/models/user.rb' },
          'Order' => { 'type' => 'model', 'file_path' => 'app/models/order.rb' }
        },
        'edges' => {
          'Order' => ['User']
        },
        'reverse' => {
          'User' => ['Order']
        },
        'file_map' => {
          'app/models/user.rb' => 'User',
          'app/models/order.rb' => 'Order'
        },
        'type_index' => {
          'model' => %w[User Order]
        }
      }

      restored = described_class.from_h(old_data)

      expect(restored.dependencies_of('Order')).to eq(['User'])
      expect(restored.dependents_of('User')).to eq(['Order'])

      edges = restored.instance_variable_get(:@edges)
      expect(edges['Order']).to eq([{ target: 'User', via: nil }])
    end
  end
end
