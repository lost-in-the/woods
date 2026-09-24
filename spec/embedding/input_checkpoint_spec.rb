# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'woods'
require 'woods/embedding/indexer'
require 'woods/embedding/text_preparer'
require 'woods/storage/vector_store'

RSpec.describe 'Prepared input checkpoint durability' do
  let(:texts) { [] }
  let(:provider) do
    double('offline provider').tap do |fake|
      allow(fake).to receive(:embed_batch) do |inputs|
        texts.concat(inputs)
        Array.new(inputs.size) { [0.2, 0.8] }
      end
    end
  end
  let(:store_class) do
    Class.new do
      include Woods::Storage::VectorStore::Interface

      attr_reader :entries, :events

      def initialize
        @entries = {}
        @events = []
      end

      def each_id(&block)
        return enum_for(:each_id) unless block_given?

        @entries.each_key(&block)
      end

      def store_batch(entries)
        @events << [:store, entries.map { |entry| entry[:id] }]
        entries.each { |entry| @entries[entry[:id]] = entry[:vector] }
      end

      def delete(id)
        @events << [:delete, id]
        @entries.delete(id)
      end
    end
  end
  let(:store) { store_class.new }
  let(:unit) do
    { 'identifier' => 'Example', 'type' => 'service', 'file_path' => 'example.rb',
      'source_code' => 'original source', 'source_hash' => 'constant',
      'chunks' => [{ 'content' => 'first' }, { 'content' => 'second' }, { 'content' => 'third' }] }
  end

  around do |example|
    Dir.mktmpdir('woods-input-checkpoint') do |dir|
      @dir = dir
      example.run
    end
  end

  def indexer
    Woods::Embedding::Indexer.new(provider: provider, text_preparer: Woods::Embedding::TextPreparer.new,
                                  vector_store: store, output_dir: @dir, batch_size: 1, checkpoint_interval: 1)
  end

  def write_unit
    File.write(File.join(@dir, 'example.json'), JSON.generate(unit))
  end

  def checkpoint_bytes
    File.binread(File.join(@dir, 'checkpoint.json'))
  end

  before do
    write_unit
    indexer.index_all
    texts.clear
    store.events.clear
  end

  it 'replaces all vectors and removes obsolete chunks before advancing the checkpoint' do
    before = checkpoint_bytes
    unit['chunks'] = [{ 'content' => 'replacement' }]
    write_unit
    allow(store).to receive(:delete).and_wrap_original do |original, id|
      expect(checkpoint_bytes).to eq(before)
      expect(store.entries).to have_key('Example')
      original.call(id)
    end

    indexer.index_incremental
    expect(store.events.first).to eq([:store, ['Example']])
    expect(store.entries.keys).to eq(['Example'])
    expect(checkpoint_bytes).not_to eq(before)
    texts.clear
    expect(indexer.index_incremental[:skipped]).to eq(1)
    expect(texts).to be_empty
  end

  it 'does not checkpoint a replacement when obsolete-chunk cleanup fails' do
    before = checkpoint_bytes
    unit['chunks'] = [{ 'content' => 'replacement' }]
    write_unit
    allow(store).to receive(:delete).and_raise(IOError, 'cleanup failed')

    expect { indexer.index_incremental }.to raise_error(Woods::Error, /Embedding failed.*Example/)
    expect(checkpoint_bytes).to eq(before)
    allow(store).to receive(:delete).and_call_original
    expect(indexer.index_incremental[:processed]).to eq(1)
    expect(store.entries.keys).to eq(['Example'])
  end

  it 'refuses a metadata-only input change when durable identities cannot be enumerated' do
    before = checkpoint_bytes
    entries = store.entries.dup
    unit['namespace'] = 'ChangedPrefix'
    write_unit
    allow(store).to receive(:each_id).and_raise(IOError, 'offline')

    expect { indexer.index_incremental }.to raise_error(Woods::Error, /existing durable vector IDs/)
    expect(checkpoint_bytes).to eq(before)
    expect(store.entries).to eq(entries)
    expect(texts).to be_empty
  end

  it 're-embeds when one expected chunk disappeared despite an unchanged input fingerprint' do
    store.entries.delete('Example#chunk_1')
    expect(indexer.index_incremental[:processed]).to eq(3)
    expect(store.entries.keys).to contain_exactly('Example#chunk_0', 'Example#chunk_1', 'Example#chunk_2')
  end

  it 'includes ordered complete chunk text in the per-unit fingerprint' do
    before = JSON.parse(checkpoint_bytes)
    unit['chunks'].reverse!
    write_unit
    expect(indexer.index_incremental[:processed]).to eq(3)
    after = JSON.parse(checkpoint_bytes)
    expect(after['hashes']).to eq(before['hashes'])
    expect(after['prepared_inputs']).not_to eq(before['prepared_inputs'])
    expect(texts.first).to end_with('third')
  end

  it 'does not re-embed metadata that never appears in the prepared input' do
    unit['metadata'] = { 'description' => 'changed display text' }
    write_unit
    expect(indexer.index_incremental[:skipped]).to eq(1)
    expect(texts).to be_empty
  end

  it 'invalidates an old preparation policy exactly once' do
    old = JSON.parse(checkpoint_bytes)
    old['preparation']['version'] = 0
    File.write(File.join(@dir, 'checkpoint.json'), JSON.generate(old))
    expect(indexer.index_incremental[:processed]).to eq(3)
    expect(indexer.index_incremental[:skipped]).to eq(1)
  end

  it 'invalidates legacy source-only checkpoints even without resolved_config' do
    File.write(File.join(@dir, 'checkpoint.json'), JSON.generate('Example' => 'constant'))
    expect(indexer.index_incremental[:processed]).to eq(3)
    expect(JSON.parse(checkpoint_bytes)['schema_version']).to eq(2)
    expect(indexer.index_incremental[:skipped]).to eq(1)
  end
end
