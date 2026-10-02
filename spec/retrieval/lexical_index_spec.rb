# frozen_string_literal: true

require 'spec_helper'
require 'woods/retrieval/lexical_index'
require 'woods/storage/metadata_store'
require 'woods/storage_identity'

RSpec.describe Woods::Retrieval::LexicalIndex do
  let(:store) { Woods::Storage::MetadataStore::InMemory.new }

  def add(identifier, type: 'model', source: '', metadata: {}, path: nil)
    key = Woods::StorageIdentity.key(identifier, type)
    store.store(key, { 'identifier' => identifier, 'type' => type, 'source_code' => source,
                       'file_path' => path, 'metadata' => metadata })
    key
  end

  def search(query, **options)
    described_class.new(metadata_store: store).execute(query: query, **options).candidates
  end

  it 'ranks exact identifiers first and preserves ambiguous typed identities' do
    first = add('Billing::Invoice')
    second = add('Billing::Invoice', type: 'service')
    add('Other', source: 'Billing Invoice ' * 50)
    expect(search('Billing::Invoice').first(2).map(&:identifier)).to match_array([first, second])
  end

  it 'splits CamelCase, snake case, paths and Unicode without matching bookkeeping' do
    target = add('ÉclairPayment', path: 'app/services/charge_card.rb')
    add('Other', metadata: { 'source_hash' => 'eclair charge card' })
    expect(search('éclair charge card').map(&:identifier)).to eq([target])
    expect(search('charge').first.matched_fields).to include('file_path:charge')
  end

  it 'finds resolved callback metadata without a literal target name' do
    target = add('Record', metadata: { 'callbacks' => { 'before_save' => ['normalize_phone'] } })
    expect(search('normalize phone').first.identifier).to eq(target)
    expect(search('normalize phone').first.matched_fields).to include('runtime:normalize')
  end

  it 'filters before the candidate limit and never seeds unrelated hubs' do
    25.times { |i| add("Noise#{i}", source: 'notify', type: 'model') }
    target = add('Delivery', source: 'notify', type: 'service')
    add('GlobalHub', metadata: { 'pagerank' => 1000 })
    expect(search('notify', type_filter: ['service'], limit: 1).map(&:identifier)).to eq([target])
    expect(search('nothing-matches')).to be_empty
    expect(search('how does the')).to be_empty
  end

  it 'excludes types and breaks equal scores deterministically' do
    add('Two', source: 'notify')
    add('One', source: 'notify')
    add('Spec', type: 'test_mapping', source: 'notify')
    results = search('notify', exclude_types: ['test_mapping'])
    expect(results.map(&:identifier)).to eq(results.map(&:identifier).sort)
    expect(results.size).to eq(2)
  end

  it 'uses an explicit exact-match tier even against a long term-rich corpus' do
    exact_name = (1..80).map { |i| "Term#{i}" }.join('::')
    target = add(exact_name, source: 'irrelevant ' * 10_000)
    30.times { |i| add("Alternative#{i}", source: exact_name.gsub('::', ' ') * 20) }
    expect(search(exact_name).first.identifier).to eq(target)
  end

  # F6 step 2. A scoped request used to build a whole new index over the
  # eligible records, re-reading and re-tokenising every one of them per
  # request (4.8 s for a 6,130-unit scope on the self-map). A view over this
  # index's own documents answers exactly what that rebuilt index did: the
  # BM25 statistics are recomputed over the subset, the documents are shared.
  it 'answers a restricted view exactly like an index built over the subset, without re-reading the store' do
    billing = add('Invoice', source: 'charge the customer ledger', path: 'packs/billing/app/models/invoice.rb')
    add('Ledger', source: 'ledger ledger entries', path: 'packs/billing/app/models/ledger.rb')
    add('Shipment', source: 'ledger of parcels', path: 'packs/shipping/app/models/shipment.rb')
    index = described_class.new(metadata_store: store)
    subset = Woods::Storage::MetadataStore::InMemory.new
    [billing, Woods::StorageIdentity.key('Ledger', 'model')].each { |key| subset.store(key, store.find(key)) }
    direct = described_class.new(metadata_store: subset)
    allow(store).to receive(:find).and_call_original

    view = index.restricted_to(subset.all_identifiers)

    expect(store).not_to have_received(:find)
    %w[ledger customer parcels Invoice].each do |query|
      shape = ->(result) { result.candidates.map { |c| [c.identifier, c.score, c.matched_fields, c.metadata] } }
      expect(shape.call(view.execute(query: query))).to eq(shape.call(direct.execute(query: query)))
    end
    # Statistics are the subset's: "ledger" is rarer in the full index than in the view.
    full_score = index.execute(query: 'ledger').candidates.find { |c| c.identifier == billing }.score
    view_score = view.execute(query: 'ledger').candidates.find { |c| c.identifier == billing }.score
    expect(view_score).not_to eq(full_score)
    expect(view.execute(query: 'parcels').candidates).to be_empty
  end

  it 'retains an immutable snapshot when the underlying store changes' do
    key = add('Record', source: 'oldword')
    index = described_class.new(metadata_store: store)
    store.store(key, { 'identifier' => 'Record', 'type' => 'model', 'source_code' => 'newword' })
    expect(index.execute(query: 'oldword').candidates.first.metadata['source_code']).to eq('oldword')
    expect(index.execute(query: 'newword').candidates).to be_empty
  end
end
