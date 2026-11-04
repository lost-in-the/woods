# frozen_string_literal: true

require 'spec_helper'
require 'woods/retriever'
require 'woods/retrieval/lexical_index'
require 'woods/retrieval/lexical_token_cache'
require 'woods/storage/metadata_store'

# When an index build reuses a unit's tokens:
#
# | indexed text (field digest) | lexical configuration | entry kept by both bounds | tokens          |
# |-----------------------------|-----------------------|---------------------------|-----------------|
# | same                        | same                  | yes                       | reused          |
# | same                        | same                  | no (aged out or bytes)    | tokenized again |
# | same                        | changed               | any                       | tokenized again |
# | changed                     | any                   | any                       | tokenized again |
#
# The unit, its key and all statistics always come from the build itself.
RSpec.describe Woods::Retrieval::LexicalTokenCache do
  let(:corpus) do
    JSON.parse(File.read(File.expand_path('../../bench/evaluation/corpus.json', __dir__), encoding: 'UTF-8'))
  end
  let(:configuration) { Woods::Retrieval::LexicalIndex.configuration_key }

  def frozen_units(records)
    records.to_h { |record| [record.fetch('identifier'), JSON.parse(JSON.generate(record), freeze: true)] }
  end

  def build(units, cache)
    Woods::Retrieval::LexicalIndex.new(units: units, token_cache: cache)
  end

  def unit(identifier, source)
    { 'identifier' => identifier, 'type' => 'model', 'file_path' => "app/models/#{identifier.downcase}.rb",
      'source_code' => source, 'metadata' => {} }
  end

  def candidates(index, query)
    index.execute(query: query).candidates.map { |c| [c.identifier, c.score, c.matched_fields, c.metadata] }
  end

  describe 'the reuse rule' do
    let(:cache) { described_class.new }

    before { build(frozen_units([unit('Ledger', 'ledger entries'), unit('Invoice', 'invoice totals')]), cache) }

    it 'reuses tokens when the indexed text and the configuration are unchanged' do
      build(frozen_units([unit('Ledger', 'ledger entries'), unit('Invoice', 'invoice totals')]), cache)
      expect(cache.stats[:last_build]).to eq(hits: 2, misses: 0)
    end

    it 'tokenizes again when one field changes by one character' do
      build(frozen_units([unit('Ledger', 'ledger entries'), unit('Invoice', 'invoice total')]), cache)
      expect(cache.stats[:last_build]).to eq(hits: 1, misses: 1)
    end

    it 'does not confuse text moved between fields' do
      moved = unit('Ledger', 'ledger entries')
              .merge('file_path' => '', 'source_code' => 'app/models/ledger.rbledger entries')
      build(frozen_units([moved]), cache)
      expect(cache.stats[:last_build]).to eq(hits: 0, misses: 1)
    end

    it 'tokenizes again under another configuration' do
      stub_const('Woods::Retrieval::LexicalIndex::TOKENIZER_VERSION',
                 Woods::Retrieval::LexicalIndex::TOKENIZER_VERSION + 1)
      build(frozen_units([unit('Ledger', 'ledger entries')]), cache)
      expect(cache.stats[:last_build]).to eq(hits: 0, misses: 1)
    end

    it 'keeps the unit, the key and the statistics of the new build' do
      changed = unit('Ledger', 'ledger entries').merge('metadata' => { 'package' => 'packs/new' })
      units = frozen_units([changed])
      index = build(units, cache)
      expect(cache.stats[:last_build]).to eq(hits: 1, misses: 0)
      expect(index.units.keys).to eq(['Ledger'])
      expect(index.units.fetch('Ledger')).to equal(units.fetch('Ledger'))
      # One document now, not two: the old build's statistics are gone.
      expect(candidates(index, 'invoice')).to be_empty
      expect(candidates(index, 'ledger')).to eq(candidates(build(frozen_units([changed]), nil), 'ledger'))
    end

    # Unknown: a build that raises part-way has tokenized some units, but
    # nothing from it is trusted later.
    it 'commits nothing from a build that raises' do
      before = cache.stats
      units = frozen_units([unit('Ledger', 'brand new words')]).merge('Broken' => unit('Broken', 'unfrozen'))
      expect { build(units, cache) }.to raise_error(ArgumentError, /must be a frozen Hash/)
      expect(cache.stats).to eq(before)
    end
  end

  describe 'bounds' do
    let(:units_a) { frozen_units([unit('Ledger', 'ledger alpha'), unit('Shared', 'shared words')]) }
    let(:units_b) { frozen_units([unit('Ledger', 'ledger beta'), unit('Shared', 'shared words')]) }
    let(:units_c) { frozen_units([unit('Ledger', 'ledger gamma'), unit('Shared', 'shared words')]) }

    it 'keeps the entries of the last two builds by default' do
      cache = described_class.new
      [units_a, units_b, units_a].each { |units| build(units, cache) }
      expect(cache.stats[:last_build]).to eq(hits: 2, misses: 0)
      [units_b, units_c, units_a].each { |units| build(units, cache) }
      expect(cache.stats[:last_build]).to eq(hits: 1, misses: 1)
      expect(cache.stats[:entries]).to eq(3)
    end

    it 'drops an entry the previous build did not use when bounded to one build' do
      cache = described_class.new(max_builds: 1)
      [units_a, units_b, units_a].each { |units| build(units, cache) }
      expect(cache.stats[:last_build]).to eq(hits: 1, misses: 1)
      expect(cache.stats[:entries]).to eq(2)
    end

    it 'stays within its byte budget, dropping the least recently used entries first' do
      probe = described_class.new
      build(units_a, probe)
      one_build = probe.stats[:bytes]
      cache = described_class.new(max_bytes: one_build)
      build(units_a, cache)
      build(units_b, cache)
      expect(cache.stats[:bytes]).to be <= one_build
      expect(cache.stats[:entries]).to eq(2)
      build(units_b, cache)
      expect(cache.stats[:last_build]).to eq(hits: 2, misses: 0)
    end

    it 'evicts retained long tokens against an independently chosen byte budget' do
      cache = described_class.new(max_bytes: 32_768)
      records = frozen_units([unit('Ledger', 'z' * 100_000)])
      index = build(records, cache)

      expect(cache.stats[:entries]).to eq(0)
      expect(cache.entries).to be_empty
      expect(candidates(index, 'ledger')).to eq(candidates(build(records, nil), 'ledger'))
    end

    it 'keeps nothing with a zero byte budget and still builds correct indexes' do
      cache = described_class.new(max_bytes: 0)
      build(units_a, cache)
      index = build(units_a, cache)
      expect(cache.stats).to include(entries: 0, bytes: 0, last_build: { hits: 0, misses: 2 })
      expect(candidates(index, 'alpha')).to eq(candidates(build(units_a, nil), 'alpha'))
    end

    it 'refuses a bound that would keep no build' do
      expect { described_class.new(max_builds: 0) }.to raise_error(ArgumentError, /max_builds/)
      expect { described_class.new(max_bytes: -1) }.to raise_error(ArgumentError, /max_bytes/)
    end
  end

  it 'holds only digests, frozen token tallies, term lists and lengths: no Class or Module object' do
    cache = described_class.new
    build(frozen_units(corpus.fetch('units')), cache)
    allowed = [String, Integer, Hash, Array]
    seen = []
    pending = cache.entries.dup
    until pending.empty?
      value = pending.pop
      seen << value
      pending.concat(value.to_a.flatten(1)) if value.is_a?(Hash)
      pending.concat(value) if value.is_a?(Array)
    end
    expect(seen).not_to be_empty
    expect(seen.grep(Module)).to be_empty
    expect(seen.map(&:class).uniq - allowed).to be_empty
    expect(seen).to all(be_frozen)
    cache.entries.each do |digest, fields, terms, lengths|
      expect(digest.bytesize).to eq(32)
      expect(fields.keys).to eq(Woods::Retrieval::LexicalIndex::FIELD_WEIGHTS.keys)
      expect(terms).to eq(fields.values.flat_map(&:keys).uniq)
      expect(lengths).to eq(fields.transform_values { |counts| counts.values.sum })
    end
  end

  # The evaluation corpus and its query set: the previous generation drops,
  # renames and edits units, and the reused build must answer every query
  # byte for byte like a cold build from the metadata store.
  it 'answers the evaluation query set byte-identically to a cold build after reuse' do
    records = corpus.fetch('units')
    previous = records.each_with_index.filter_map do |record, position|
      next if (position % 11).zero?

      record = record.merge('identifier' => "#{record['identifier']}Old") if (position % 13).zero?
      record = record.merge('source_code' => "#{record['source_code']}\n# edited") if (position % 7).zero?
      record
    end
    cache = described_class.new
    build(frozen_units(previous), cache)
    reused = build(frozen_units(records), cache)
    stats = cache.stats[:last_build]
    expect(stats[:hits]).to be > records.size / 2
    expect(stats[:misses]).to be_positive

    store = Woods::Storage::MetadataStore::InMemory.new
    records.each { |record| store.store(record.fetch('identifier'), record) }
    cold = Woods::Retriever.new(vector_store: nil, metadata_store: store, graph_store: nil,
                                embedding_provider: nil, mode: :lexical)
    warm = Woods::Retriever.new(vector_store: nil, metadata_store: store, graph_store: nil,
                                embedding_provider: nil, mode: :lexical, lexical_index: reused)
    corpus.fetch('queries').each do |query|
      options = { budget: query.fetch('budget') }
      options[:types] = query['types'] if query['types']
      expected = cold.retrieve(query.fetch('query'), **options)
      actual = warm.retrieve(query.fetch('query'), **options)
      expect(JSON.generate(actual.to_h.slice(:context, :sources, :tokens_used)))
        .to eq(JSON.generate(expected.to_h.slice(:context, :sources, :tokens_used))), query.fetch('id')
      expect(candidates(reused, query.fetch('query')))
        .to eq(candidates(cold.pipeline.executor, query.fetch('query'))), query.fetch('id')
    end
  end
end
