# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'woods'
require 'woods/embedding/indexer'
require 'woods/embedding/text_preparer'
require 'woods/embedding/fake'
require 'woods/storage/snapshotter'
require 'woods/mcp/bootstrapper'

RSpec.describe 'SQLite metadata in local embedding' do
  include_context 'isolated Woods runtime'

  around do |example|
    Dir.mktmpdir('woods-sqlite-embedding') do |directory|
      @output_dir = directory
      previous_purge = ENV.delete('WOODS_ALLOW_PURGE')
      example.run
    ensure
      previous_purge ? ENV['WOODS_ALLOW_PURGE'] = previous_purge : ENV.delete('WOODS_ALLOW_PURGE')
    end
  end

  let(:provider) { Woods::Embedding::Provider::Fake.new(dims: 8) }
  let(:vectors) { Woods::Storage::VectorStore::InMemory.new }
  let(:metadata) { Woods::Storage::MetadataStore::SQLite.new(database: File.join(@output_dir, 'metadata.sqlite3')) }
  let(:artifact) { Woods::IndexArtifact.new(@output_dir) }

  def indexer(vector_store: vectors, metadata_store: metadata, **options)
    Woods::Embedding::Indexer.new(provider: provider, text_preparer: Woods::Embedding::TextPreparer.new,
                                  vector_store: vector_store, metadata_store: metadata_store,
                                  output_dir: @output_dir, **options)
  end

  def write_unit(identifier, type: 'model', source: 'class Example; end', chunks: [])
    unit = { type: type, identifier: identifier, file_path: "app/#{type}s/#{identifier}.rb",
             source_code: source, source_hash: Digest::SHA256.hexdigest(source),
             dependencies: [], chunks: chunks }
    path = File.join(@output_dir, "#{type}_#{identifier}.json")
    File.write(path, JSON.generate(unit))
    path
  end

  def published_ids
    Woods::Storage::Snapshotter::Vector.load_or_empty(artifact).each_entry.map { |id, _vector, _metadata| id }
  end

  def write_survivors
    4.times { |index| write_unit("Keep#{index}") }
  end

  [false, true].each do |fresh_vectors|
    it "removes stale and vectorless SQLite records on full rebuild with fresh vectors=#{fresh_vectors}" do
      write_unit('Keep')
      gone = write_unit('Gone', chunks: [{ content: 'first' }, { content: 'second' }])
      empty_gone = write_unit('EmptyGone', source: '')
      indexer.index_all
      expect(metadata.all_identifiers).to contain_exactly('Keep', 'Gone', 'EmptyGone')
      File.unlink(gone)
      File.unlink(empty_gone)
      rebuilt_vectors = fresh_vectors ? Woods::Storage::VectorStore::InMemory.new : vectors

      expect(indexer(vector_store: rebuilt_vectors).index_all).to eq(processed: 1, skipped: 0, errors: 0)

      expect(metadata.all_identifiers).to eq(['Keep'])
      expect(metadata.search('Gone')).to be_empty
      expect(published_ids).to eq(['Keep'])
    end
  end

  it 'removes all SQLite records when a full rebuild intentionally has no units' do
    paths = [write_unit('Gone'), write_unit('EmptyGone', source: '')]
    indexer.index_all
    paths.each { |path| File.unlink(path) }

    expect(indexer(vector_store: Woods::Storage::VectorStore::InMemory.new).index_all)
      .to eq(processed: 0, skipped: 0, errors: 0)
    expect(metadata.all_identifiers).to be_empty
    expect(published_ids).to be_empty
  end

  it 'removes deleted vectorless SQLite records on a fresh incremental run below the purge threshold' do
    write_survivors
    gone = write_unit('EmptyGone', source: '')
    indexer.index_all
    File.unlink(gone)
    reopened = Woods::Storage::MetadataStore::SQLite.new(database: File.join(@output_dir, 'metadata.sqlite3'))
    calls = provider.calls.size

    expect(indexer(vector_store: Woods::Storage::VectorStore::InMemory.new, metadata_store: reopened).index_incremental)
      .to eq(processed: 0, skipped: 4, errors: 0)

    expect(reopened.all_identifiers).to match_array(4.times.map { |index| "Keep#{index}" })
    expect(provider.calls.size).to eq(calls)
    expect(published_ids.size).to eq(4)
  end

  it 'removes deleted vector chunks and SQLite records together on incremental runs' do
    write_survivors
    gone = write_unit('Gone', chunks: [{ content: 'first' }, { content: 'second' }])
    indexer.index_all
    File.unlink(gone)

    indexer(vector_store: Woods::Storage::VectorStore::InMemory.new).index_incremental

    expect(metadata.find('Gone')).to be_nil
    expect(published_ids).not_to include('Gone#chunk_0', 'Gone#chunk_1')
  end

  [false, true].each do |empty_corpus|
    it "keeps the incremental purge guard for vectorless SQLite records with empty corpus=#{empty_corpus}" do
      keep = write_unit('Keep')
      gone = write_unit('EmptyGone', source: '')
      indexer.index_all
      File.unlink(gone)
      File.unlink(keep) if empty_corpus
      promoted = artifact.latest_dump_path
      calls = provider.calls.size

      expect { indexer(vector_store: Woods::Storage::VectorStore::InMemory.new).index_incremental }
        .to output(/refusing to prune/).to_stderr

      expect(metadata.all_identifiers).to contain_exactly('Keep', 'EmptyGone')
      expect(artifact.latest_dump_path).to eq(promoted)
      expect(provider.calls.size).to eq(calls)
      ENV['WOODS_ALLOW_PURGE'] = '1'
      indexer(vector_store: Woods::Storage::VectorStore::InMemory.new).index_incremental
      expect(metadata.all_identifiers).to eq(empty_corpus ? [] : ['Keep'])
    end
  end

  it 'retains a surviving vectorless typed key across a full rebuild and later deletes only that record' do
    write_survivors
    empty = write_unit('reports', type: 'factory', source: '')
    sibling = write_unit('reports', type: 'database_view')
    indexer.index_all
    key = Woods::StorageIdentity.key('reports', 'factory')
    File.unlink(sibling)

    indexer(vector_store: Woods::Storage::VectorStore::InMemory.new).index_all

    expect(metadata.find(key)).to include('type' => 'factory', 'identifier' => 'reports')
    expect(metadata.find('reports')).to be_nil
    expect(metadata.find(Woods::StorageIdentity.key('reports', 'database_view'))).to be_nil
    File.unlink(empty)
    indexer(vector_store: Woods::Storage::VectorStore::InMemory.new).index_incremental
    expect(metadata.all_identifiers).to match_array(4.times.map { |index| "Keep#{index}" })
  end

  it 'refuses incomplete input before changing SQLite, vectors or checkpoint, even with purge override' do
    write_unit('Keep')
    gone = write_unit('Gone', source: '')
    indexer.index_all
    File.unlink(gone)
    File.write(File.join(@output_dir, 'invalid.json'), '{broken')
    checkpoint = File.binread(File.join(@output_dir, 'checkpoint.json'))
    promoted = artifact.latest_dump_path
    calls = provider.calls.size
    ENV['WOODS_ALLOW_PURGE'] = '1'

    expect { indexer.index_incremental }.to raise_error(Woods::Error, /Embedding input incomplete/)

    expect(metadata.all_identifiers).to contain_exactly('Keep', 'Gone')
    expect(File.binread(File.join(@output_dir, 'checkpoint.json'))).to eq(checkpoint)
    expect(artifact.latest_dump_path).to eq(promoted)
    expect(provider.calls.size).to eq(calls)
  end

  it 'backfills typed vector filters from the same configured SQLite store used by standalone retrieval' do
    config = Woods::Builder.preset_config(:local)
    config.output_dir = @output_dir
    config.embedding_provider = :fake
    config.embedding_options = { dims: 8 }
    resolved = Woods::ResolvedConfig.from_configuration(config, provider: provider)
    write_unit('reports', type: 'factory', chunks: [{ content: 'report factory' }, { content: 'report trait' }])
    write_unit('reports', type: 'database_view', source: 'SELECT report FROM entries')
    indexer(resolved_config: resolved).index_all
    stores = []
    allow(Woods::Storage::MetadataStore::SQLite).to receive(:new).and_wrap_original do |original, **options|
      original.call(**options).tap { |store| stores << store }
    end

    retriever, state = Woods::MCP::Bootstrapper.build_retriever(index_dir: @output_dir)

    expect(state.status).to eq(:hydrated)
    expect(stores).to eq([retriever.metadata_store])
    %w[factory database_view].each do |type|
      key = Woods::StorageIdentity.key('reports', type)
      hits = retriever.vector_store.search(provider.embed('reports'), limit: 5, filters: { type: [type] })
      expected_ids = type == 'factory' ? ["#{key}#chunk_0", "#{key}#chunk_1"] : [key]
      expect(hits.map(&:id)).to match_array(expected_ids)
      result = retriever.retrieve('Explain reports', types: [type])
      expect(result.sources.map { |source| [source[:identifier], source[:type]] }).to eq([['reports', type]])
    end
  end
end
