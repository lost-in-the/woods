# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'woods/embedding/indexer'
require 'woods/embedding/text_preparer'
require 'woods/storage/vector_store'
require 'woods/storage/metadata_store'
require 'woods/storage/snapshotter'
require 'woods/index_artifact'

RSpec.describe 'Full embedding with reused snapshot stores' do
  let(:output_dir) { Dir.mktmpdir('woods_full_embedding') }
  let(:vectors) { Woods::Storage::VectorStore::InMemory.new }
  let(:metadata) { Woods::Storage::MetadataStore::InMemory.new }
  let(:provider) { double('provider') }
  let(:artifact) { Woods::IndexArtifact.new(output_dir) }
  let(:indexer) do
    Woods::Embedding::Indexer.new(provider: provider, text_preparer: Woods::Embedding::TextPreparer.new,
                                  vector_store: vectors, metadata_store: metadata,
                                  output_dir: output_dir, batch_size: 1)
  end

  before { allow(provider).to receive(:embed_batch) { |texts| texts.map { [0.1, 0.2] } } }
  after { FileUtils.rm_rf(output_dir) }

  def write_unit(identifier, source: 'class Example; end', chunks: [])
    unit = {
      type: 'model', identifier: identifier, file_path: "#{identifier}.rb", source_code: source,
      source_hash: Digest::SHA256.hexdigest(source), dependencies: [], chunks: chunks
    }
    File.write(File.join(output_dir, "#{identifier}.json"), JSON.generate(unit))
  end

  def published_ids
    Woods::Storage::Snapshotter::Vector.load_or_empty(artifact).each_entry.map { |id, *_rest| id }.sort
  end

  def published_metadata_ids
    Woods::Storage::Snapshotter::Metadata.load_or_empty(artifact).each_entry.map { |id, *_rest| id }.sort
  end

  it 'removes vanished vectors, chunks and metadata-only records before promoting a full rebuild' do
    write_unit('Keep')
    write_unit('Gone', chunks: [{ content: 'first chunk' }, { content: 'second chunk' }])
    write_unit('EmptyGone', source: '')
    indexer.index_all
    expect(published_ids).to eq(['Gone#chunk_0', 'Gone#chunk_1', 'Keep'])
    expect(published_metadata_ids).to eq(%w[EmptyGone Gone Keep])

    File.unlink(File.join(output_dir, 'Gone.json'))
    File.unlink(File.join(output_dir, 'EmptyGone.json'))
    expect(indexer.index_all).to eq(processed: 1, skipped: 0, errors: 0)

    expect(vectors.each_entry.map { |id, *_rest| id }).to eq(['Keep'])
    expect(metadata.each_entry.map { |id, *_rest| id }).to eq(['Keep'])
    expect(published_ids).to eq(['Keep'])
    expect(published_metadata_ids).to eq(['Keep'])
  end

  it 'publishes an empty full rebuild, including removal of metadata-only records' do
    write_unit('Gone')
    write_unit('EmptyGone', source: '')
    indexer.index_all
    File.unlink(File.join(output_dir, 'Gone.json'))
    File.unlink(File.join(output_dir, 'EmptyGone.json'))

    expect(indexer.index_all).to eq(processed: 0, skipped: 0, errors: 0)
    expect(published_ids).to eq([])
    expect(published_metadata_ids).to eq([])
    expect(JSON.parse(File.read(File.join(output_dir, 'checkpoint.json')))).to eq({})
  end

  it 'preserves the promoted dump and checkpoint when a later provider batch fails' do
    write_unit('Gone')
    indexer.index_all
    original_dump = File.binread(File.join(output_dir, 'dumps/latest'))
    checkpoint = File.binread(File.join(output_dir, 'checkpoint.json'))
    File.unlink(File.join(output_dir, 'Gone.json'))
    write_unit('First')
    write_unit('Second')
    calls = 0
    allow(provider).to receive(:embed_batch) do |texts|
      calls += 1
      raise 'provider unavailable' if calls == 2

      texts.map { [0.3, 0.4] }
    end

    expect { indexer.index_all }.to raise_error(Woods::Error, /provider unavailable/)
    expect(File.binread(File.join(output_dir, 'dumps/latest'))).to eq(original_dump)
    expect(File.binread(File.join(output_dir, 'checkpoint.json'))).to eq(checkpoint)
    expect(published_ids).to eq(['Gone'])
    expect(published_metadata_ids).to eq(['Gone'])
  end
end
