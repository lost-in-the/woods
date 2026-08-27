# frozen_string_literal: true

require 'spec_helper'
require 'woods/storage/metadata_store'

RSpec.describe Woods::Storage::MetadataStore do
  # The #search contract every adapter must honour — see the doc comment on
  # MetadataStore::Interface#search. Builder swaps these adapters freely, so a
  # behavioural difference means the same query returns different results
  # depending on which backend a host configured.
  #
  # B-097 / #209 covered field-name validation and LIKE metacharacters.
  # #218 / B-105 closed the remaining divergence: InMemory was case-sensitive
  # (String#include?) while SQLite was ASCII case-insensitive (LIKE). Both are
  # case-insensitive now, and the whole contract is pinned here rather than
  # documented as a known difference.
  shared_examples 'hardened search' do
    describe 'search hardening (B-097 / #209)' do
      before do
        store.store('Coupon', { type: 'model', description: '50% off promo' })
        store.store('FiftyOff', { type: 'model', description: '50 dollars off promo' })
        store.store('Snake', { type: 'model', description: 'user_name column' })
        store.store('NotSnake', { type: 'model', description: 'userXname column' })
      end

      it 'raises ArgumentError for a field name that breaks out of a JSON-path literal' do
        expect { store.search('x', fields: ["description') OR 1=1 --"]) }
          .to raise_error(ArgumentError, /Invalid search field/)
      end

      it 'raises ArgumentError for a field name containing a quote' do
        expect { store.search('x', fields: ["desc'ription"]) }
          .to raise_error(ArgumentError, /Invalid search field/)
      end

      it 'raises ArgumentError for a field name starting with a digit' do
        expect { store.search('x', fields: %w[1description]) }
          .to raise_error(ArgumentError, /Invalid search field/)
      end

      it 'still accepts symbol field names' do
        ids = store.search('user_name', fields: [:description]).map { |r| r['id'] }
        expect(ids).to eq(['Snake'])
      end

      it 'treats % in the query as a literal, not a wildcard' do
        ids = store.search('50% off', fields: ['description']).map { |r| r['id'] }
        expect(ids).to eq(['Coupon']) # pre-fix, LIKE '%50% off%' also matched FiftyOff
      end

      it 'treats _ in the query as a literal, not a single-character wildcard' do
        ids = store.search('user_name', fields: ['description']).map { |r| r['id'] }
        expect(ids).to eq(['Snake']) # pre-fix, LIKE '%user_name%' also matched NotSnake
      end

      it 'treats metacharacters literally on the all-fields path too' do
        ids = store.search('user_name').map { |r| r['id'] }
        expect(ids).to eq(['Snake'])
      end
    end

    describe 'search semantics (#218 / B-105)' do
      before do
        store.store('Invoice', { type: 'model', description: 'Handles Billing And Payments' })
      end

      it 'matches case-insensitively when the query is lowercase' do
        ids = store.search('billing', fields: ['description']).map { |r| r['id'] }
        expect(ids).to eq(['Invoice'])
      end

      it 'matches case-insensitively when the stored value differs in case' do
        ids = store.search('HANDLES', fields: ['description']).map { |r| r['id'] }
        expect(ids).to eq(['Invoice'])
      end

      it 'matches case-insensitively on the all-fields path' do
        ids = store.search('bILLing').map { |r| r['id'] }
        expect(ids).to eq(['Invoice'])
      end

      it 'matches a substring rather than requiring a whole word' do
        ids = store.search('ayment', fields: ['description']).map { |r| r['id'] }
        expect(ids).to eq(['Invoice'])
      end

      # fields: nil serializes the record, so keys are part of the haystack.
      it 'can match a field name on the all-fields path' do
        ids = store.search('description').map { |r| r['id'] }
        expect(ids).to eq(['Invoice'])
      end

      it 'returns nothing when the query matches no record' do
        expect(store.search('nonexistent-token', fields: ['description'])).to be_empty
      end

      # `updated_at` is a store-managed timestamp, not caller-supplied data —
      # SQLite's `data` column never includes it, so a whole-record query that
      # only matched the timestamp used to return every record on InMemory
      # (which serialized it into the JSON haystack) and none on SQLite.
      # `#find`/`#search` both strip `updated_at` from what they return, so
      # there's no public accessor for the stored value — the ISO date
      # `#store` wrote it with (Time.now.iso8601, same instant as the
      # `before` block above) is reconstructed here instead.
      it 'does not match on the store-managed updated_at timestamp (all-fields path)' do
        today_fragment = Time.now.strftime('%Y-%m-%d')
        expect(store.search(today_fragment)).to be_empty
      end
    end
  end

  describe 'Interface contract' do
    let(:dummy_class) do
      Class.new do
        include Woods::Storage::MetadataStore::Interface
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

  describe Woods::Storage::MetadataStore::SQLite do
    let(:store) { described_class.new(database: ':memory:') }

    describe 'database path configuration' do
      it 'accepts only the database keyword' do
        Dir.mktmpdir('woods-metadata-contract') do |dir|
          database = File.join(dir, 'metadata.sqlite3')

          expect { described_class.new(database: database) }.not_to raise_error
          expect { described_class.new(database) }.to raise_error(ArgumentError)
        end
      end
    end

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

    include_examples 'hardened search'

    describe 'hostile field names (SQLite-specific)' do
      it 'executes no SQL when a field name fails validation' do
        db = store.instance_variable_get(:@db)
        expect(db).not_to receive(:execute)

        expect { store.search('x', fields: ["a') OR 1=1 --"]) }
          .to raise_error(ArgumentError, /Invalid search field/)
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

    describe 'missing sqlite3 gem' do
      it 'raises a friendly Woods::ConfigurationError instead of LoadError' do
        # Simulate the gem not being present in the host bundle.
        original_method = Kernel.instance_method(:require)
        allow_any_instance_of(Woods::Storage::MetadataStore::SQLite)
          .to receive(:require).with('sqlite3').and_raise(LoadError)

        expect { described_class.new(database: ':memory:') }
          .to raise_error(Woods::ConfigurationError, /sqlite3 gem.+Gemfile.+:in_memory/m)
      ensure
        Kernel.send(:define_method, :require, original_method) if original_method
      end
    end
  end

  describe Woods::Storage::MetadataStore::InMemory do
    let(:store) { described_class.new }

    # The in-memory adapter and the SQLite adapter must be substitutable
    # — Builder picks one based on config without the rest of the pipeline
    # caring. These specs lock the contract: same shape in, same shape out.

    describe '#store / #count / #find' do
      it 'tracks count and round-trips a record' do
        expect(store.count).to eq(0)

        store.store('User', { type: 'model', file_path: 'app/models/user.rb' })
        expect(store.count).to eq(1)

        result = store.find('User')
        expect(result['type']).to eq('model')
        expect(result['file_path']).to eq('app/models/user.rb')
      end

      it 'upserts on duplicate IDs' do
        store.store('User', { type: 'model', version: 1 })
        store.store('User', { type: 'model', version: 2 })

        expect(store.count).to eq(1)
        expect(store.find('User')['version']).to eq(2)
      end

      it 'returns nil for missing IDs' do
        expect(store.find('Nonexistent')).to be_nil
      end

      it 'stringifies symbol keys to match the SQLite contract' do
        store.store('User', { type: :model, namespace: :Admin })

        result = store.find('User')
        expect(result['type']).to eq(:model)
        expect(result['namespace']).to eq(:Admin)
      end
    end

    describe '#find_by_type' do
      before do
        store.store('User', { type: 'model' })
        store.store('Order', { type: 'model' })
        store.store('AuthService', { type: 'service' })
      end

      it 'returns all units of the given type' do
        results = store.find_by_type('model')

        expect(results.map { |r| r['id'] }).to contain_exactly('User', 'Order')
      end

      it 'accepts symbol types' do
        expect(store.find_by_type(:service).map { |r| r['id'] }).to eq(['AuthService'])
      end
    end

    describe '#search' do
      before do
        store.store('User', { type: 'model', description: 'User account model' })
        store.store('AuthService', { type: 'service', description: 'Authentication service' })
      end

      it 'searches across all metadata fields by default' do
        ids = store.search('account').map { |r| r['id'] }
        expect(ids).to eq(['User'])
      end

      it 'restricts to specified fields when given' do
        ids = store.search('account', fields: ['description']).map { |r| r['id'] }
        expect(ids).to eq(['User'])
      end

      it 'returns empty when nothing matches' do
        expect(store.search('nope')).to be_empty
      end
    end

    include_examples 'hardened search'

    describe '#delete' do
      it 'removes a unit by ID' do
        store.store('User', { type: 'model' })
        store.delete('User')

        expect(store.find('User')).to be_nil
        expect(store.count).to eq(0)
      end
    end

    describe '#find_batch' do
      it 'returns a hash of id => record for found ids' do
        store.store('User', { type: 'model' })
        store.store('Order', { type: 'model' })

        result = store.find_batch(%w[User Order Missing])

        expect(result.keys).to contain_exactly('User', 'Order')
        expect(result['User']['type']).to eq('model')
      end
    end
  end
end
