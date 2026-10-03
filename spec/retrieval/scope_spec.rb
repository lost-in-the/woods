# frozen_string_literal: true

require 'spec_helper'
require 'woods/retrieval/scope'
require 'woods/retrieval/scope_corpus'

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

  # F6 step 1. Building a scope used to deep-copy every record through a JSON
  # round trip before validating it, validate the contributor records once for
  # the package check and twice more per record for eligibility, then copy the
  # eligible subset again into the scope's own store. Each record is now read
  # once, its contributors validated once, and copied once (by the store).
  it 'reads and validates each record once while building the scope' do
    invoice = add('Invoice', package: 'packs/billing', path: 'packs/billing/app/models/invoice.rb')
    add('Shared', path: 'app/models/shared.rb')
    allow(Woods::SourceContributors).to receive(:records).and_call_original
    allow(store).to receive(:find).and_call_original
    allow(JSON).to receive(:generate).and_call_original

    resolved = scope(packages: ['packs/billing'])

    expect(resolved.keys).to eq([invoice])
    expect(store).to have_received(:find).exactly(store.count).times
    expect(Woods::SourceContributors).to have_received(:records).exactly(store.count).times
    # One JSON.generate per eligible record: the copy the scope's own store makes.
    expect(JSON).to have_received(:generate).exactly(resolved.keys.size).times
  end

  # F6 step 2. The retriever and the Index Server share one corpus (one read
  # of the store) across scoped requests; a scope resolved from it must be
  # the scope the store form resolves, without touching the store again.
  it 'resolves the same scope from a shared corpus as from the store, reading nothing from the store' do
    add('Invoice', package: 'packs/billing', path: 'packs/billing/app/models/invoice.rb')
    add('Shared', path: 'app/models/shared.rb')
    add('Spec', type: 'test_mapping', path: 'app/models/shared.rb')
    corpus = Woods::Retrieval::ScopeCorpus.from_store(store)
    requests = [{ packages: ['packs/billing'] }, { source_paths: ['app'], types: ['model'] },
                { source_paths: ['app'], exclude_types: ['test_mapping'] }, { packages: ['packs/empty'] }]
    allow(store).to receive(:find).and_call_original
    allow(store).to receive(:all_identifiers).and_call_original

    shared = requests.map { |request| described_class.new(corpus: corpus, **request) }

    expect(store).not_to have_received(:find)
    expect(store).not_to have_received(:all_identifiers)
    requests.zip(shared).each do |request, resolved|
      reference = scope(**request)
      expect(resolved.keys).to eq(reference.keys)
      expect(resolved.summary).to eq(reference.summary)
      expect(resolved.metadata_store.all_identifiers).to eq(reference.metadata_store.all_identifiers)
      expect(resolved.metadata_store.find_batch(reference.keys))
        .to eq(reference.metadata_store.find_batch(reference.keys))
    end
  end

  it 'keeps a corpus-backed scope immutable after the live store changes' do
    key = add('Invoice', package: 'packs/billing')
    resolved = described_class.new(corpus: Woods::Retrieval::ScopeCorpus.from_store(store), packages: ['packs/billing'])
    store.delete(key)
    expect(resolved.metadata_store.find(key)['identifier']).to eq('Invoice')
    expect(resolved.include?("#{key}#chunk_2")).to be(true)
  end

  it 'validates lists and package names identically from a corpus, and needs exactly one source' do
    corpus = Woods::Retrieval::ScopeCorpus.from_store(store)
    expect { described_class.new(corpus: corpus, packages: ['packs/missing']) }
      .to raise_error(described_class::InvalidScopeError, /unknown package/)
    expect { described_class.new(corpus: corpus, source_paths: ['../app']) }
      .to raise_error(described_class::InvalidScopeError)
    expect { described_class.new(corpus: corpus, metadata_store: store) }.to raise_error(ArgumentError)
    expect { described_class.new(packages: ['.']) }.to raise_error(ArgumentError)
  end

  it 'resolves eligibility from a facts-only corpus and refuses to hand out its records' do
    key = add('Invoice', package: 'packs/billing')
    facts = Woods::Retrieval::ScopeCorpus.from_store(store, records: :none)
    resolved = described_class.new(corpus: facts, packages: ['packs/billing'])
    expect(resolved.keys).to eq([key])
    expect(resolved.summary).to include(eligible_units: 1)
    expect { resolved.metadata_store }.to raise_error(described_class::InvalidScopeError, /records/)
  end

  it 'holds no reference to the ineligible records once the store form has copied the eligible ones' do
    add('Invoice', package: 'packs/billing')
    add('Other', package: '.')
    resolved = scope(packages: ['packs/billing'])
    expect(resolved.instance_variables).not_to include(:@corpus)
    expect(resolved.metadata_store.count).to eq(1)
  end

  it 'treats empty lists as unscoped without requiring metadata reads' do
    expect(described_class.requested?(packages: [], source_paths: nil)).to be(false)
    expect(described_class.requested?(packages: ['.'], source_paths: [])).to be(true)
  end
end
