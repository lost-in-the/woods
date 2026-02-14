# frozen_string_literal: true

require 'spec_helper'
require 'codebase_index/storage/metadata_store'

RSpec.describe CodebaseIndex::Storage::MetadataStore do
  describe 'Interface contract' do
    let(:dummy_class) do
      Class.new do
        include CodebaseIndex::Storage::MetadataStore::Interface
      end
    end

    let(:dummy) { dummy_class.new }

    it 'raises NotImplementedError for #store' do
      expect { dummy.store('id', {}) }.to raise_error(NotImplementedError)
    end

    it 'raises NotImplementedError for #find' do
      expect { dummy.find('id') }.to raise_error(NotImplementedError)
    end

    it 'raises NotImplementedError for #find_by_type' do
      expect { dummy.find_by_type('model') }.to raise_error(NotImplementedError)
    end

    it 'raises NotImplementedError for #search' do
      expect { dummy.search('query') }.to raise_error(NotImplementedError)
    end

    it 'raises NotImplementedError for #delete' do
      expect { dummy.delete('id') }.to raise_error(NotImplementedError)
    end

    it 'raises NotImplementedError for #count' do
      expect { dummy.count }.to raise_error(NotImplementedError)
    end
  end

  describe CodebaseIndex::Storage::MetadataStore::SQLite do
    let(:store) { described_class.new(':memory:') }

    describe '#store and #count' do
      it 'stores metadata and tracks count' do
        expect(store.count).to eq(0)

        store.store('User', { type: 'model', file_path: 'app/models/user.rb' })
        expect(store.count).to eq(1)

        store.store('Order', { type: 'model', file_path: 'app/models/order.rb' })
        expect(store.count).to eq(2)
      end

      it 'upserts on duplicate IDs' do
        store.store('User', { type: 'model', version: 1 })
        store.store('User', { type: 'model', version: 2 })

        expect(store.count).to eq(1)

        result = store.find('User')
        expect(result['version']).to eq(2)
      end
    end

    describe '#find' do
      it 'returns metadata for existing ID' do
        store.store('User', { type: 'model', namespace: 'Admin', associations: %w[Post Comment] })

        result = store.find('User')

        expect(result['type']).to eq('model')
        expect(result['namespace']).to eq('Admin')
        expect(result['associations']).to eq(%w[Post Comment])
      end

      it 'returns nil for missing ID' do
        expect(store.find('Nonexistent')).to be_nil
      end

      it 'round-trips complex JSON metadata' do
        metadata = {
          type: 'model',
          callbacks: [{ name: 'before_save', method: 'validate_name' }],
          associations: { has_many: ['posts'], belongs_to: ['organization'] },
          nested: { deep: { value: 42 } }
        }

        store.store('User', metadata)
        result = store.find('User')

        expect(result['callbacks']).to eq([{ 'name' => 'before_save', 'method' => 'validate_name' }])
        expect(result['associations']['has_many']).to eq(['posts'])
        expect(result['nested']['deep']['value']).to eq(42)
      end
    end

    describe '#find_by_type' do
      before do
        store.store('User', { type: 'model', file_path: 'app/models/user.rb' })
        store.store('Order', { type: 'model', file_path: 'app/models/order.rb' })
        store.store('AuthService', { type: 'service', file_path: 'app/services/auth_service.rb' })
      end

      it 'returns all units of the given type' do
        results = store.find_by_type('model')

        expect(results.size).to eq(2)
        ids = results.map { |r| r['id'] }
        expect(ids).to contain_exactly('User', 'Order')
      end

      it 'returns empty array for unknown type' do
        results = store.find_by_type('nonexistent')

        expect(results).to be_empty
      end

      it 'accepts symbol types' do
        results = store.find_by_type(:model)

        expect(results.size).to eq(2)
      end
    end

    describe '#search' do
      before do
        store.store('User', { type: 'model', file_path: 'app/models/user.rb', description: 'User account model' })
        store.store('AuthService', { type: 'service', file_path: 'app/services/auth_service.rb',
                                     description: 'Authentication service' })
        store.store('UsersController', { type: 'controller', file_path: 'app/controllers/users_controller.rb',
                                         description: 'Manages user resources' })
      end

      it 'searches across all metadata fields' do
        results = store.search('user')

        ids = results.map { |r| r['id'] }
        expect(ids).to include('User', 'UsersController')
      end

      it 'searches specific fields' do
        results = store.search('user', fields: ['description'])

        ids = results.map { |r| r['id'] }
        expect(ids).to include('User', 'UsersController')
        expect(ids).not_to include('AuthService')
      end

      it 'returns empty array when no matches' do
        results = store.search('nonexistent_term')

        expect(results).to be_empty
      end
    end

    describe '#delete' do
      it 'removes a unit by ID' do
        store.store('User', { type: 'model' })
        store.store('Order', { type: 'model' })

        store.delete('User')

        expect(store.count).to eq(1)
        expect(store.find('User')).to be_nil
        expect(store.find('Order')).not_to be_nil
      end

      it 'does nothing for nonexistent IDs' do
        store.store('User', { type: 'model' })

        store.delete('Nonexistent')

        expect(store.count).to eq(1)
      end
    end
  end
end
