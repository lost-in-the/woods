# frozen_string_literal: true

require 'spec_helper'
require 'codebase_index/storage/graph_store'

RSpec.describe CodebaseIndex::Storage::GraphStore do
  describe 'Interface contract' do
    let(:dummy_class) do
      Class.new do
        include CodebaseIndex::Storage::GraphStore::Interface
      end
    end

    let(:dummy) { dummy_class.new }

    it 'raises NotImplementedError for #dependencies_of' do
      expect { dummy.dependencies_of('User') }.to raise_error(NotImplementedError)
    end

    it 'raises NotImplementedError for #dependents_of' do
      expect { dummy.dependents_of('User') }.to raise_error(NotImplementedError)
    end

    it 'raises NotImplementedError for #affected_by' do
      expect { dummy.affected_by(['file.rb']) }.to raise_error(NotImplementedError)
    end

    it 'raises NotImplementedError for #by_type' do
      expect { dummy.by_type(:model) }.to raise_error(NotImplementedError)
    end

    it 'raises NotImplementedError for #pagerank' do
      expect { dummy.pagerank }.to raise_error(NotImplementedError)
    end
  end

  describe CodebaseIndex::Storage::GraphStore::Memory do
    let(:store) { described_class.new }

    # Helper to create a minimal ExtractedUnit
    def make_unit(type:, identifier:, file_path: nil, dependencies: [])
      unit = CodebaseIndex::ExtractedUnit.new(
        type: type,
        identifier: identifier,
        file_path: file_path || "/app/#{identifier.underscore}.rb"
      )
      unit.dependencies = dependencies
      unit
    end

    describe '#register and #dependencies_of' do
      it 'registers units and tracks forward dependencies' do
        user = make_unit(type: :model, identifier: 'User')
        order = make_unit(
          type: :model,
          identifier: 'Order',
          dependencies: [{ type: :model, target: 'User' }]
        )

        store.register(user)
        store.register(order)

        expect(store.dependencies_of('Order')).to include('User')
        expect(store.dependencies_of('User')).to be_empty
      end
    end

    describe '#dependents_of' do
      it 'returns reverse dependencies' do
        user = make_unit(type: :model, identifier: 'User')
        service = make_unit(
          type: :service,
          identifier: 'UserService',
          dependencies: [{ type: :model, target: 'User' }]
        )

        store.register(user)
        store.register(service)

        expect(store.dependents_of('User')).to include('UserService')
        expect(store.dependents_of('UserService')).to be_empty
      end
    end

    describe '#affected_by' do
      before do
        store.register(make_unit(type: :model, identifier: 'User', file_path: 'app/models/user.rb'))
        store.register(make_unit(
                         type: :service, identifier: 'UserService',
                         file_path: 'app/services/user_service.rb',
                         dependencies: [{ type: :model, target: 'User' }]
                       ))
        store.register(make_unit(
                         type: :controller, identifier: 'UsersController',
                         file_path: 'app/controllers/users_controller.rb',
                         dependencies: [{ type: :service, target: 'UserService' }]
                       ))
      end

      it 'returns transitively affected units' do
        affected = store.affected_by(['app/models/user.rb'])

        expect(affected).to include('User', 'UserService', 'UsersController')
      end

      it 'respects max_depth' do
        affected = store.affected_by(['app/models/user.rb'], max_depth: 1)

        expect(affected).to include('User', 'UserService')
        expect(affected).not_to include('UsersController')
      end

      it 'returns empty for unrelated files' do
        affected = store.affected_by(['app/models/product.rb'])

        expect(affected).to be_empty
      end
    end

    describe '#by_type' do
      before do
        store.register(make_unit(type: :model, identifier: 'User'))
        store.register(make_unit(type: :model, identifier: 'Order'))
        store.register(make_unit(type: :service, identifier: 'AuthService'))
      end

      it 'returns units of the given type' do
        models = store.by_type(:model)

        expect(models).to contain_exactly('User', 'Order')
      end

      it 'returns empty array for unknown type' do
        expect(store.by_type(:nonexistent)).to be_empty
      end
    end

    describe '#pagerank' do
      it 'returns empty hash for empty graph' do
        expect(store.pagerank).to eq({})
      end

      it 'computes importance scores' do
        store.register(make_unit(type: :model, identifier: 'User'))
        store.register(make_unit(type: :model, identifier: 'Order',
                                 dependencies: [{ type: :model, target: 'User' }]))
        store.register(make_unit(type: :service, identifier: 'UserService',
                                 dependencies: [{ type: :model, target: 'User' }]))
        store.register(make_unit(type: :model, identifier: 'Product'))

        scores = store.pagerank

        expect(scores['User']).to be > scores['Product']
      end

      it 'accepts custom damping and iterations' do
        store.register(make_unit(type: :model, identifier: 'A'))
        store.register(make_unit(type: :model, identifier: 'B',
                                 dependencies: [{ type: :model, target: 'A' }]))

        scores = store.pagerank(damping: 0.5, iterations: 10)

        expect(scores).to have_key('A')
        expect(scores).to have_key('B')
      end
    end

    describe 'wrapping an existing DependencyGraph' do
      it 'delegates to the provided graph' do
        graph = CodebaseIndex::DependencyGraph.new
        graph.register(make_unit(type: :model, identifier: 'User'))

        store = described_class.new(graph)

        expect(store.by_type(:model)).to include('User')
      end
    end
  end
end
