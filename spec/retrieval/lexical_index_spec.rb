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

  it 'retains an immutable snapshot when the underlying store changes' do
    key = add('Record', source: 'oldword')
    index = described_class.new(metadata_store: store)
    store.store(key, { 'identifier' => 'Record', 'type' => 'model', 'source_code' => 'newword' })
    expect(index.execute(query: 'oldword').candidates.first.metadata['source_code']).to eq('oldword')
    expect(index.execute(query: 'newword').candidates).to be_empty
  end
end
