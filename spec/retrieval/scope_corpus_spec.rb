# frozen_string_literal: true

require 'spec_helper'
require 'woods/retrieval/scope_corpus'
require 'woods/retrieval/scope'

# F6 step 2. A scope used to read and validate every metadata record per
# request. The corpus is that read done once per store snapshot, shared by
# every scope resolved against it; a view over the eligible keys answers the
# metadata store reads the scoped pipeline makes, exactly as the per-request
# store copy did.
RSpec.describe Woods::Retrieval::ScopeCorpus do
  let(:store) { Woods::Storage::MetadataStore::InMemory.new }

  def add(name, type: 'model', package: nil, path: nil, **extra)
    key = Woods::StorageIdentity.key(name, type)
    store.store(key, { identifier: name, type: type, file_path: path, metadata: { package: package } }.merge(extra))
    key
  end

  def legacy(**options)
    Woods::Retrieval::Scope.new(metadata_store: store, **options)
  end

  before do
    %w[. packs/billing packs/empty].each { |name| add(name, type: 'package', path: "#{name}/package.yml") }
  end

  describe '.from_store' do
    it 'reads and validates every record once, in key order, and carries the store version' do
      invoice = add('Invoice', package: 'packs/billing', path: 'packs/billing/app/models/invoice.rb')
      shared = add('Shared', path: 'app/models/shared.rb')
      allow(store).to receive(:find).and_call_original
      allow(Woods::SourceContributors).to receive(:records).and_call_original

      corpus = described_class.from_store(store)

      expect(corpus.keys).to eq(store.all_identifiers.sort)
      expect(corpus.snapshot_version).to eq(store.snapshot_version)
      expect(corpus.package_names).to include('.', 'packs/billing', 'packs/empty')
      expect(store).to have_received(:find).exactly(store.count).times
      expect(Woods::SourceContributors).to have_received(:records).exactly(store.count).times
      fact = corpus.fact(invoice)
      expect([fact.type, fact.owners, fact.paths])
        .to eq(['model', ['packs/billing'], ['packs/billing/app/models/invoice.rb']])
      expect(corpus.fact(shared).owners).to eq([nil])
      expect(corpus.fact('missing')).to be_nil
    end

    it 'refuses a missing record and propagates invalid contributor provenance' do
      key = add('Invoice', package: 'packs/billing')
      allow(store).to receive(:all_identifiers).and_return([key, 'missing'])
      expect { described_class.from_store(store) }
        .to raise_error(Woods::Retrieval::Scope::InvalidScopeError, /missing metadata/)

      allow(store).to receive(:all_identifiers).and_call_original
      add('Lib', type: 'lib', metadata: { source_contributors: 'bad', source_contributors_version: 1 })
      expect { described_class.from_store(store) }.to raise_error(Woods::SourceContributors::Invalid)
    end

    it 'keeps its own immutable copy of every record' do
      key = add('Invoice', package: 'packs/billing', source_code: 'before')
      corpus = described_class.from_store(store)

      # A caller that mutates a record it read from the live store reaches the
      # store's own entry, never the corpus.
      store.find(key)['metadata']['package'] = 'packs/empty'
      expect(store.find(key)['metadata']['package']).to eq('packs/empty')
      store.store(key, { identifier: 'Invoice', type: 'model', source_code: 'after', metadata: {} })
      store.delete(key)

      record = corpus.fact(key).record
      expect(record['source_code']).to eq('before')
      expect(record['metadata']).to eq('package' => 'packs/billing')
      expect([record, record['metadata']]).to all(be_frozen)
    end

    it 'can keep facts only, for a caller that never reads records through it' do
      key = add('Invoice', package: 'packs/billing')
      allow(JSON).to receive(:generate).and_call_original

      facts = described_class.from_store(store, records: :none)

      expect(JSON).not_to have_received(:generate)
      expect(facts.keys).to eq(store.all_identifiers.sort)
      expect(facts.fact(key).record).to be_nil
      expect(facts.fact(key).owners).to eq(['packs/billing'])
      expect { facts.view([key]) }.to raise_error(Woods::Retrieval::Scope::InvalidScopeError, /records/)
    end
  end

  describe '.from_units' do
    it 'shares already-immutable records without copying them' do
      key = add('Invoice', package: 'packs/billing')
      record = JSON.parse(JSON.generate(store.find(key)))
      record.each_value(&:freeze).freeze
      allow(JSON).to receive(:generate).and_call_original

      corpus = described_class.from_units({ key => record }, snapshot_version: 7)

      expect(JSON).not_to have_received(:generate)
      expect(corpus.fact(key).record).to equal(record)
      expect(corpus.snapshot_version).to eq(7)
      expect(corpus.keys).to eq([key])
      expect(corpus.package_names).to eq(Set['packs/billing'])
      expect(corpus.view([key]).find(key)).to eq(record)
    end

    it 'refuses duplicate keys and non-record entries' do
      expect { described_class.from_units([['A', { 'type' => 'model' }], ['A', { 'type' => 'model' }]]) }
        .to raise_error(Woods::Retrieval::Scope::InvalidScopeError, /duplicate/)
      expect { described_class.from_units({ 'A' => nil }) }
        .to raise_error(Woods::Retrieval::Scope::InvalidScopeError, /missing metadata/)
    end
  end

  describe '#view' do
    it 'answers every metadata store read exactly like the per-request scope store did' do
      add('Invoice', package: 'packs/billing', path: 'packs/billing/app/models/invoice.rb',
                     description: 'Billing Invoice', flags: { active: true, count: 2 }, source_code: '50% off_')
      add('Invoice', type: 'service', package: 'packs/billing', path: 'packs/billing/app/services/invoice.rb')
      outside = add('Outside', package: '.', description: 'Billing elsewhere')
      reference = legacy(packages: ['packs/billing']).metadata_store
      keys = reference.all_identifiers.sort
      corpus = described_class.from_store(store)

      view = corpus.view(keys)

      expect(view.all_identifiers).to eq(reference.all_identifiers)
      expect(view.count).to eq(reference.count)
      expect(view.snapshot_version).to eq(corpus.snapshot_version)
      keys.each { |key| expect(view.find(key)).to eq(reference.find(key)) }
      expect(view.find(outside)).to be_nil
      expect(view.find_batch(keys + [outside, 'missing'])).to eq(reference.find_batch(keys + [outside, 'missing']))
      %w[model service package].each { |type| expect(view.find_by_type(type)).to eq(reference.find_by_type(type)) }
      expect(view.find_by_type(:model)).to eq(reference.find_by_type(:model))
      [['invoice', nil], ['INVOICE', ['identifier']], ['billing', %w[description]], ['true', ['flags']],
       ['"count":2', nil], ['50%', ['source_code']], ['off_', ['source_code']], ['zzz', nil], ['invoice', []],
       ['billing', %i[description identifier]]].each do |query, fields|
        expect(view.search(query, fields: fields)).to eq(reference.search(query, fields: fields))
      end
      expect(view.search('invoice').map { |record| record['id'] }).to eq(keys)
      expect { view.search('x', fields: ['bad name']) }.to raise_error(ArgumentError)
      expect(view.local_corpus_stats).to eq(reference.local_corpus_stats)
      expect(view.local_corpus_stats(include_types: false)).to eq(reference.local_corpus_stats(include_types: false))
      expect(view.transaction { :done }).to eq(:done)
    end

    it 'is read-only, hands out records a caller may extend but not corrupt, and refuses foreign keys' do
      key = add('Invoice', package: 'packs/billing')
      corpus = described_class.from_store(store)
      view = corpus.view([key])

      expect { view.store(key, { type: 'model' }) }.to raise_error(FrozenError)
      expect { view.delete(key) }.to raise_error(FrozenError)
      expect(view).not_to respond_to(:clear!)
      expect(view).not_to respond_to(:bulk_load)
      record = view.find(key)
      record['id'] = key
      expect(view.find(key)).not_to have_key('id')
      expect { record['metadata']['package'] = 'x' }.to raise_error(FrozenError)
      expect { corpus.view([key, 'missing']) }
        .to raise_error(Woods::Retrieval::Scope::InvalidScopeError, /missing metadata/)
    end
  end
end
