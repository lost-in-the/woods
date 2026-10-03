# frozen_string_literal: true

require 'spec_helper'
require 'woods/retriever'
require 'woods/storage/vector_store'
require 'woods/storage/metadata_store'
require 'woods/storage/graph_store'

RSpec.describe 'Explicit retrieval scope' do
  let(:metadata) { Woods::Storage::MetadataStore::InMemory.new }
  let(:vectors) { Woods::Storage::VectorStore::InMemory.new }
  let(:graph) { Woods::Storage::GraphStore::Memory.new }
  let(:provider) { double('Embedding provider', embed: [1.0, 0.0]) }
  let(:retriever) do
    Woods::Retriever.new(metadata_store: metadata, vector_store: vectors, graph_store: graph,
                         embedding_provider: provider)
  end

  def add(name, package: 'packs/billing', type: 'model', vector: [1.0, 0.1])
    key = Woods::StorageIdentity.key(name, type)
    metadata.store(key, { identifier: name, type: type, file_path: "#{package}/app/#{name}.rb",
                          source_code: "class #{name}; def billing; end; end", metadata: { package: package } })
    # Existing entries need no package or base-identifier vector payload.
    vectors.store(key, vector, {})
    key
  end

  it 'finds a small package before vector limits even when global results are dominated elsewhere' do
    25.times { |i| add("Noise#{i}", package: 'packs/other', vector: [1.0, 0.0]) }
    add('Invoice')
    result = retriever.retrieve('How does billing work?', packages: ['packs/billing'])
    expect(result.sources.map { |source| source[:identifier] }).to eq(['Invoice'])
    expect(result.applied_scope).to include(eligible_units: 1, outcome: :matched)
    expect(provider).to have_received(:embed).once
  end

  %i[keyword direct graph hybrid].each do |strategy|
    it "applies eligibility before #{strategy} limits and graph expansion" do
      outside = add('Outside', package: 'packs/other')
      inside = add('Invoice')
      unit = Woods::ExtractedUnit.new(identifier: 'Invoice', type: :model, file_path: 'invoice.rb')
      unit.dependencies = [{ target: 'Outside', type: :model, via: :calls }]
      graph.register(unit)
      scope = Woods::Retrieval::Scope.new(metadata_store: metadata, packages: ['packs/billing'])
      pipeline = retriever.send(:scoped_pipeline, retriever.pipeline, scope)
      classification = Woods::Retrieval::QueryClassifier.new.classify('Invoice billing')
      execution = pipeline.executor.execute(query: 'Invoice billing', classification: classification,
                                            strategy: strategy, limit: 1)
      expect(execution.candidates.map(&:identifier)).to include(inside)
      expect(execution.candidates.map(&:identifier)).not_to include(outside, 'Outside')
    end
  end

  it 'uses authoritative type eligibility for legacy vectors during within-type fallback' do
    add('Invoice')
    result = retriever.retrieve('find zzzzz', packages: ['packs/billing'], types: ['model'])
    expect(result.sources.map { |source| source[:identifier] }).to eq(['Invoice'])
    expect(result.type_rank_context).to be_nil
    expect(result.applied_scope).to include(outcome: :matched)
  end

  it 'reports populated no-match separately from an empty eligible population' do
    add('Invoice')
    lexical = Woods::Retriever.new(metadata_store: metadata, vector_store: nil, graph_store: nil,
                                   embedding_provider: nil, mode: :lexical)
    expect(lexical.retrieve('zzzzz',
                            packages: ['packs/billing']).applied_scope).to include(outcome: :no_match,
                                                                                   eligible_units: 1)
    expect(lexical.retrieve('billing', packages: ['packs/billing'], types: ['controller']).applied_scope)
      .to include(outcome: :empty_scope, eligible_units: 0)
  end

  # F6 step 2. The scope's read of the metadata store happens once per store
  # snapshot, not per request: the pipeline keeps the corpus while the
  # store's version stands, and reads again only after a content change.
  it 'reads the metadata store once across scoped requests and again only after it changes' do
    add('Invoice')
    add('Outside', package: 'packs/other')
    reference = retriever.retrieve('How does billing work?', packages: ['packs/billing'])
    allow(metadata).to receive(:find).and_call_original
    allow(metadata).to receive(:all_identifiers).and_call_original

    first = retriever.retrieve('How does billing work?', packages: ['packs/billing'])
    second = retriever.retrieve('billing', packages: ['packs/billing'], types: ['model'])

    expect(metadata).not_to have_received(:find)
    expect(metadata).not_to have_received(:all_identifiers)
    expect([first.context, first.sources]).to eq([reference.context, reference.sources])
    expect(second.sources.map { |source| source[:identifier] }).to eq(['Invoice'])

    add('Statement')
    third = retriever.retrieve('billing', packages: ['packs/billing'])
    expect(metadata).to have_received(:all_identifiers).once
    expect(metadata).to have_received(:find).exactly(metadata.count).times
    expect(third.sources.map { |source| source[:identifier] }).to contain_exactly('Invoice', 'Statement')
    expect(third.applied_scope).to include(eligible_units: 2)
  end

  it 'reads a store that tracks no changes on every scoped request, with the same answer' do
    durable = Woods::Storage::MetadataStore::SQLite.new(database: ':memory:')
    add('Invoice')
    add('Outside', package: 'packs/other')
    metadata.all_identifiers.each { |key| durable.store(key, metadata.find(key)) }
    reference = retriever.retrieve('How does billing work?', packages: ['packs/billing'])
    versionless = Woods::Retriever.new(metadata_store: durable, vector_store: vectors, graph_store: graph,
                                       embedding_provider: provider)
    allow(durable).to receive(:find).and_call_original

    results = Array.new(2) { versionless.retrieve('How does billing work?', packages: ['packs/billing']) }

    expect(durable).to have_received(:find).at_least(2 * durable.count).times
    results.each { |result| expect([result.context, result.sources]).to eq([reference.context, reference.sources]) }
  end

  it 'keeps unscoped calls byte-identical and leaves scope metadata absent' do
    add('Invoice')
    ordinary = retriever.retrieve('How does billing work?')
    empty = retriever.retrieve('How does billing work?', packages: [], source_paths: [])
    expect(empty.context).to eq(ordinary.context)
    expect(empty.sources).to eq(ordinary.sources)
    expect(empty.applied_scope).to be_nil
  end
end
