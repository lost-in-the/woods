# frozen_string_literal: true

require 'spec_helper'
require 'woods/retrieval/scope'

RSpec.describe Woods::Retrieval::Scope do
  let(:store) { Woods::Storage::MetadataStore::InMemory.new }

  def add(name, type: 'model', package: nil, path: nil)
    key = Woods::StorageIdentity.key(name, type)
    store.store(key, { identifier: name, type: type, file_path: path, metadata: { package: package } })
    key
  end

  def scope(**options)
    described_class.new(metadata_store: store, **options)
  end

  before do
    %w[. packs/billing packs/billing/nested packs/billing_admin packs/empty].each do |name|
      add(name, type: 'package', path: "#{name}/package.yml")
    end
  end

  it 'uses exact nearest package ownership, including the root package' do
    billing = add('Invoice', package: 'packs/billing')
    nested = add('Nested', package: 'packs/billing/nested')
    root = add('Root', package: '.')
    add('UnknownOwner')
    expect(scope(packages: ['packs/billing']).keys).to eq([billing])
    expect(scope(packages: ['.']).keys).to eq([root])
    expect(scope(packages: %w[packs/billing packs/billing/nested]).keys).to match_array([billing, nested])
  end

  it 'normalizes relative directory prefixes at path segment boundaries' do
    target = add('Invoice', path: 'packs/billing/app/models/invoice.rb')
    add('Admin', path: 'packs/billing_admin/app/models/invoice.rb')
    resolved = scope(source_paths: ['./packs//billing/.'], types: ['model'])
    expect(resolved.source_paths).to eq(['packs/billing'])
    expect(resolved.keys).to eq([target])
  end

  it 'combines each list with OR and package/path/type dimensions with AND' do
    target = add('Invoice', package: 'packs/billing', path: 'packs/billing/app/models/invoice.rb')
    add('Invoice', type: 'service', package: 'packs/billing', path: 'packs/billing/app/services/invoice.rb')
    add('WrongOwner', package: '.', path: 'packs/billing/app/models/wrong.rb')
    paths = %w[packs/billing/app/services packs/billing/app/models]
    expect(scope(packages: %w[. packs/billing], source_paths: paths,
                 types: ['model'], exclude_types: ['model']).keys).to match_array([target,
                                                                                   Woods::StorageIdentity.key(
                                                                                     'WrongOwner', 'model'
                                                                                   )])
    expect(scope(packages: ['packs/billing'], source_paths: ['packs/billing/app/models']).keys).to eq([target])
  end

  it 'lets path scope find units without package metadata and excludes external or missing paths' do
    target = add('Invoice', path: 'app/models/invoice.rb')
    add('External', path: '/gems/external.rb')
    add('Missing')
    expect(scope(source_paths: ['.'], types: ['model']).keys).to eq([target])
  end

  it 'rejects malformed scope lists and escaping paths before reading stores' do
    expect(store).not_to receive(:all_identifiers)
    [nil, '', '/app', '../app', 'app/../../etc', "app\0models", 'C:/app', 'app\\models'].each do |path|
      expect { scope(source_paths: [path]) }.to raise_error(described_class::InvalidScopeError)
    end
    expect { scope(packages: 'packs/billing') }.to raise_error(described_class::InvalidScopeError)
    expect { scope(source_paths: [12]) }.to raise_error(described_class::InvalidScopeError)
  end

  it 'normalizes internal parent segments without accepting an out-of-root traversal' do
    expect(scope(source_paths: ['packs/other/../billing']).source_paths).to eq(['packs/billing'])
  end

  it 'distinguishes an unknown package from a known package with zero eligible units' do
    expect { scope(packages: ['packs/missing']) }.to raise_error(described_class::InvalidScopeError, /unknown package/)
    expect(scope(packages: ['packs/empty'], types: ['model']).summary).to include(eligible_units: 0)
  end

  it 'preserves typed identities and identifies chunk ownership without conflating same-name units' do
    model = add('Shared', package: 'packs/billing')
    service = add('Shared', type: 'service', package: 'packs/billing_admin')
    resolved = scope(packages: ['packs/billing'])
    expect(resolved.include?("#{model}#chunk_1")).to be(true)
    expect(resolved.include?(service)).to be(false)
    expect(resolved.include?('Shared')).to be(false)
  end

  it 'captures one immutable metadata view and refuses missing records' do
    key = add('Invoice', package: 'packs/billing')
    resolved = scope(packages: ['packs/billing'])
    store.delete(key)
    expect(resolved.metadata_store.find(key)['identifier']).to eq('Invoice')
    allow(store).to receive(:all_identifiers).and_return([key])
    expect { scope(packages: ['packs/billing']) }.to raise_error(described_class::InvalidScopeError, /missing metadata/)
  end

  it 'treats empty lists as unscoped without requiring metadata reads' do
    expect(described_class.requested?(packages: [], source_paths: nil)).to be(false)
    expect(described_class.requested?(packages: ['.'], source_paths: [])).to be(true)
  end
end
