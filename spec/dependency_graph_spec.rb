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

    # #205 — out-degree was counted over raw edges while contributions were
    # summed over the deduplicated reverse Set, so a source with two edges to
    # one target (`:belongs_to` + `:code_reference` is documented normal, see
    # #dependents_detail) delivered only half its mass.
    context 'when a source has two edges to one target (#205)' do
      before do
        graph.register(make_unit(type: :model, identifier: 'User'))
        graph.register(make_unit(type: :model, identifier: 'Account'))
        graph.register(make_unit(
                         type: :model, identifier: 'Order',
                         dependencies: [
                           { type: :model, target: 'User', via: :belongs_to },
                           { type: :model, target: 'User', via: :code_reference },
                           { type: :model, target: 'Account', via: :belongs_to }
                         ]
                       ))
      end

      it 'conserves total mass' do
        total = graph.pagerank.values.sum
        expect(total).to be_within(0.01).of(1.0)
      end

      it 'ranks the twice-referenced target above the once-referenced one' do
        scores = graph.pagerank
        expect(scores['User']).to be > scores['Account']
      end
    end

    # #205 — an edge to a target that is not a registered node (a gem or
    # framework constant) inflated out-degree, so its share of the source's
    # mass vanished from the system every iteration.
    context 'when edges point at unregistered targets (#205)' do
      before do
        graph.register(make_unit(type: :model, identifier: 'User'))
        graph.register(make_unit(
                         type: :service, identifier: 'Signup',
                         dependencies: [
                           { type: :model, target: 'User', via: :code_reference },
                           { type: :service, target: 'Stripe::Client', via: :code_reference }
                         ]
                       ))
      end

      it 'conserves total mass' do
        total = graph.pagerank.values.sum
        expect(total).to be_within(0.01).of(1.0)
      end

      it 'treats a node whose every edge is unresolvable as dangling' do
        graph.register(make_unit(
                         type: :service, identifier: 'Webhook',
                         dependencies: [{ type: :service, target: 'Stripe::Event', via: :code_reference }]
                       ))

        total = graph.pagerank.values.sum
        expect(total).to be_within(0.01).of(1.0)
      end
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

  describe '#find_all_by_suffix' do
    before do
      graph.register(make_unit(type: :service, identifier: 'Order::Update'))
      graph.register(make_unit(type: :service, identifier: 'User::Update'))
      graph.register(make_unit(type: :model, identifier: 'Product'))
    end

    it 'returns every namespaced identifier sharing the suffix' do
      expect(graph.find_all_by_suffix('Update')).to contain_exactly('Order::Update', 'User::Update')
    end

    it 'returns an empty array when nothing matches' do
      expect(graph.find_all_by_suffix('NonExistent')).to eq([])
    end

    it 'returns an empty array for an exact-match identifier (suffix requires a :: prefix)' do
      expect(graph.find_all_by_suffix('Product')).to eq([])
    end

    it 'does not change find_node_by_suffix\'s existing single-result contract' do
      expect(graph.find_node_by_suffix('Update')).to eq(graph.find_all_by_suffix('Update').min)
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

    it 'widens a single-valued file_map from a pre-migration graph (#164 gap 3)' do
      restored = described_class.from_h(
        'nodes' => { 'User' => { 'type' => 'model', 'file_path' => 'app/models/user.rb' } },
        'file_map' => { 'app/models/user.rb' => 'User' }
      )

      expect(restored.identifiers_for_path('app/models/user.rb')).to eq(['User'])
    end

    it 'round-trips a multi-valued file_map through JSON' do
      graph.register(make_unit(type: :rake_task, identifier: 'db:seed', file_path: '/app/lib/tasks/db.rake'))
      graph.register(make_unit(type: :rake_task, identifier: 'db:reset', file_path: '/app/lib/tasks/db.rake'))

      restored = described_class.from_h(JSON.parse(JSON.generate(graph.to_h)))

      expect(restored.identifiers_for_path('/app/lib/tasks/db.rake')).to contain_exactly('db:seed', 'db:reset')
    end
  end

  # A single file can define several units — a .rake file with several tasks,
  # an i18n YAML, a lib file with several classes. Before #164 the file map
  # kept only the last-registered identifier per path, so anything reached
  # *from* a path was lossy and units could ghost.
  describe 'multi-unit files' do
    before do
      graph.register(make_unit(type: :rake_task, identifier: 'db:seed', file_path: '/app/lib/tasks/db.rake'))
      graph.register(make_unit(type: :rake_task, identifier: 'db:reset', file_path: '/app/lib/tasks/db.rake'))
    end

    it 'keeps every identifier defined by one path' do
      expect(graph.identifiers_for_path('/app/lib/tasks/db.rake')).to contain_exactly('db:seed', 'db:reset')
    end

    it 'marks every unit in the file as affected by a change to it' do
      expect(graph.affected_by(['/app/lib/tasks/db.rake'])).to contain_exactly('db:seed', 'db:reset')
    end

    it 'drops only the removed identifier from the path' do
      graph.remove('db:seed')

      expect(graph.identifiers_for_path('/app/lib/tasks/db.rake')).to eq(['db:reset'])
    end

    it 'forgets the path once its last unit is removed' do
      graph.remove('db:seed')
      graph.remove('db:reset')

      expect(graph.registered_paths).not_to include('/app/lib/tasks/db.rake')
    end
  end

  describe '#remove' do
    before do
      graph.register(make_unit(type: :model, identifier: 'User'))
      graph.register(
        make_unit(type: :service, identifier: 'Signup', dependencies: [{ target: 'User', via: :code_reference }])
      )
    end

    it 'returns the removed node the first time and nil after' do
      expect(graph.remove('Signup')).to include(type: :service)
      expect(graph.remove('Signup')).to be_nil
    end

    it 'drops the node, its edges, and its type-index entry' do
      graph.remove('Signup')

      expect(graph.node_exists?('Signup')).to be(false)
      expect(graph.dependencies_of('Signup')).to be_empty
      expect(graph.units_of_type(:service)).to be_empty
    end

    it 'drops the type bucket entirely rather than leaving it empty' do
      graph.remove('Signup')

      expect(graph.to_h[:type_index]).not_to have_key(:service)
      expect(graph.to_h[:stats][:types]).not_to have_key(:service)
    end

    it 'withdraws the removed unit from its targets reverse edges' do
      graph.remove('Signup')

      expect(graph.dependents_of('User')).to be_empty
      expect(graph.dependents_of('User', via: :code_reference)).to be_empty
    end

    it 'leaves reverse edges pointing at the removed unit alone' do
      # Signup still declares an edge to User, so a full extraction would
      # record that reverse entry too — a dependency target need not be a
      # registered node.
      graph.remove('User')

      expect(graph.dependents_of('User')).to eq(['Signup'])
    end

    it 'invalidates the memoized serialization' do
      graph.to_h
      graph.remove('Signup')

      expect(graph.to_h[:nodes]).not_to have_key('Signup')
    end
  end

  describe '#dependents_detail' do
    it 'reports the dependent type alongside the identifier' do
      graph.register(make_unit(type: :model, identifier: 'User'))
      graph.register(
        make_unit(type: :service, identifier: 'Signup', dependencies: [{ target: 'User', via: :code_reference }])
      )

      expect(graph.dependents_detail('User')).to eq([{ type: :service, identifier: 'Signup' }])
    end

    it 'preserves multiplicity when one unit references a target twice' do
      graph.register(make_unit(type: :model, identifier: 'User'))
      graph.register(
        make_unit(
          type: :model, identifier: 'Order',
          dependencies: [{ target: 'User', via: :belongs_to }, { target: 'User', via: :code_reference }]
        )
      )

      expect(graph.dependents_detail('User').size).to eq(2)
    end

    it 'ignores dependents that are not registered nodes' do
      expect(graph.dependents_detail('Nobody')).to be_empty
    end
  end

  # #166 — the index has to be readable off the machine that wrote it. Extraction
  # in a container writes /app/...; a host reading the volume mount sees a
  # different absolute prefix, so absolute paths in the artifact made the graph's
  # path index resolve to nothing there.
  describe 'path portability (#166)' do
    let(:root) { '/srv/app' }

    before { stub_const('Rails', double('Rails', root: Pathname.new(root))) }

    def graph_with_unit(file_path)
      unit = Woods::ExtractedUnit.new(type: :model, identifier: 'User', file_path: file_path)
      described_class.new.tap { |g| g.register(unit) }
    end

    it 'persists node file_path relative to the root' do
      data = graph_with_unit("#{root}/app/models/user.rb").to_h

      expect(data[:nodes]['User'][:file_path]).to eq('app/models/user.rb')
    end

    it 'persists file_map keys relative to the root' do
      data = graph_with_unit("#{root}/app/models/user.rb").to_h

      expect(data[:file_map].keys).to eq(['app/models/user.rb'])
    end

    it 'keeps absolute paths in memory, which is what File.exist? callers need' do
      graph = graph_with_unit("#{root}/app/models/user.rb")

      expect(graph.node('User')[:file_path]).to eq("#{root}/app/models/user.rb")
      expect(graph.identifiers_for_path("#{root}/app/models/user.rb")).to eq(['User'])
    end

    it 'leaves out-of-tree paths alone' do
      data = graph_with_unit('/gems/activerecord/lib/base.rb').to_h

      expect(data[:nodes]['User'][:file_path]).to eq('/gems/activerecord/lib/base.rb')
    end

    it 'round-trips back to absolute paths' do
      original = graph_with_unit("#{root}/app/models/user.rb")
      restored = described_class.from_h(JSON.parse(JSON.generate(original.to_h)))

      expect(restored.node('User')[:file_path]).to eq("#{root}/app/models/user.rb")
      expect(restored.identifiers_for_path("#{root}/app/models/user.rb")).to eq(['User'])
    end

    # The whole point: a graph this version writes under one prefix resolves
    # under another. Extraction in a container, Index Server on the host.
    it 'resolves a graph written under one root against a different one' do
      written_in_container = JSON.parse(
        JSON.generate(graph_with_unit("#{root}/app/models/user.rb").to_h)
      )

      stub_const('Rails', double('Rails', root: Pathname.new('/host/checkout')))
      rehydrated = described_class.from_h(written_in_container)

      expect(rehydrated.identifiers_for_path('/host/checkout/app/models/user.rb')).to eq(['User'])
      expect(rehydrated.node('User')[:file_path]).to eq('/host/checkout/app/models/user.rb')
    end

    # Stated limitation rather than a gap: a graph written *before* #166 holds
    # absolute paths, and there is no way to know which prefix was that machine's
    # root, so it cannot be re-pointed. It loads and works in place — which is
    # what keeps it from needing a re-index — and becomes portable the next time
    # a full extraction rewrites it.
    it 'cannot re-point a pre-migration graph at a different root' do
      pre_migration = {
        'nodes' => { 'User' => { 'type' => 'model', 'file_path' => '/app/app/models/user.rb' } },
        'file_map' => { '/app/app/models/user.rb' => ['User'] }
      }

      stub_const('Rails', double('Rails', root: Pathname.new('/host/checkout')))
      restored = described_class.from_h(pre_migration)

      expect(restored.identifiers_for_path('/app/app/models/user.rb')).to eq(['User'])
      expect(restored.identifiers_for_path('/host/checkout/app/models/user.rb')).to be_empty
    end

    # A pre-#166 graph is already absolute; absolutizing must be idempotent so it
    # loads without a re-index, the way normalize_edges/normalize_file_map do.
    it 'loads a pre-migration absolute-keyed graph unchanged' do
      restored = described_class.from_h(
        'nodes' => { 'User' => { 'type' => 'model', 'file_path' => "#{root}/app/models/user.rb" } },
        'file_map' => { "#{root}/app/models/user.rb" => ['User'] }
      )

      expect(restored.identifiers_for_path("#{root}/app/models/user.rb")).to eq(['User'])
    end

    it 'keeps file_map values as Sets so unregister can delete from them' do
      graph = graph_with_unit("#{root}/app/models/user.rb")
      restored = described_class.from_h(JSON.parse(JSON.generate(graph.to_h)))

      expect { restored.unregister('User') }.not_to raise_error
      expect(restored.identifiers_for_path("#{root}/app/models/user.rb")).to be_empty
    end
  end
end
