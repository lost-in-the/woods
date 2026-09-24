# frozen_string_literal: true

require 'spec_helper'
require 'woods/extractors/lib_extractor'
require 'woods/chunking/semantic_chunker'
require 'woods/embedding/text_preparer'
require 'woods/embedding/indexer'
require 'woods/mcp/bootstrapper'
require 'woods/retriever'

RSpec.describe 'Contributor-aware library embeddings' do
  include_context 'extractor setup'

  let(:originals) do
    { 'lib/a.rb' => "module LibraryChunks\n  FIRST = '漢🙂'\nend\n",
      'lib/b.rb' => "module LibraryChunks\n  SECOND = '#{'é' * 140}'\nend\n" }
  end
  let(:unit) do
    originals.each { |path, source| create_file(path, source) }
    Woods::Extractors::LibExtractor.new.extract_all.fetch(0)
  end

  def expect_exact_location(chunk)
    location = chunk.fetch(:metadata).fetch(:physical_location)
    original = originals.fetch(location.fetch(:file_path))
    expect(original.byteslice(location[:start_byte]...location[:end_byte])).to eq(chunk.fetch(:content))
    expect(location[:source_sha256]).to eq(Digest::SHA256.hexdigest(original))
    expect_physical_lines(location, original, chunk[:content])
    expect_published_bytes(chunk)
  end

  def expect_published_bytes(chunk)
    published = chunk[:metadata].fetch(:published_location)
    expect(unit.source_code.byteslice(published[:start_byte]...published[:end_byte])).to eq(chunk[:content])
  end

  def expect_physical_lines(location, original, content)
    expect(location[:start_line]).to eq(original.byteslice(0...location[:start_byte]).count("\n") + 1)
    expect(location[:end_line]).to eq(location[:start_line] + content.delete_suffix("\n").count("\n"))
  end

  it 'keeps small contributors separate and emits original bytes without composite headers' do
    chunks = Woods::Chunking::SemanticChunker.new(threshold: 100_000).chunk(unit)
    expect(chunks.map(&:content)).to eq(originals.values)
    chunks.each { |chunk| expect_exact_location(chunk.to_h) }
  end

  it 'keeps direct whole-unit preparation complete with an explicit composite label' do
    text = Woods::Embedding::TextPreparer.new.prepare(unit)
    expect(text).to include(*originals.values, 'primary file:', 'contributing files: lib/a.rb, lib/b.rb')
    expect(unit.chunks).to be_empty
  end

  it 'adjusts physical and published spans through semantic and repeated provider splitting' do
    chunker = Woods::Chunking::SemanticChunker.new(max_chars: 80)
    unit.chunks = chunker.chunk(unit).map(&:to_h)
    unit.chunks.each { |chunk| expect_exact_location(chunk) }
    Woods::Chunking::SemanticChunker.new(max_chars: 50).enforce_chunk_limits!(unit)
    unit.chunks.each { |chunk| expect_exact_location(chunk) }
    preparer = Woods::Embedding::TextPreparer.new
    [110, 70].each do |limit|
      budget = Woods::Embedding::InputBudget.new(limit: limit, method: 'utf8_bytes_bound')
      texts = preparer.prepare_for_embedding(unit, budget: budget)
      expect(texts.map(&:bytesize)).to all(be <= limit)
      texts.zip(unit.chunks).each do |text, chunk|
        expect_exact_location(chunk)
        expect(text).to include("file: #{chunk[:metadata][:physical_location][:file_path]}\n")
      end
      expect(unit.chunks.map { |chunk| chunk[:content] }.join).to eq(originals.values.join)
    end
  end

  it 'rebuilds arbitrary prechunks instead of retaining cross-file or forged citations' do
    unit.chunks = [{ content: unit.source_code, metadata: { physical_location: { file_path: 'lib/a.rb' } } }]
    texts = Woods::Embedding::TextPreparer.new.prepare_for_embedding(unit)
    expect(texts.size).to eq(2)
    unit.chunks.each { |chunk| expect_exact_location(chunk) }
    expect(texts.last).to include('file: lib/b.rb')
    expect(texts.last).not_to include('file: lib/a.rb', 'Library contributor:')
  end

  it 'retains typed contributor metadata and vector spans through indexing and hydration' do
    data = JSON.parse(JSON.generate(unit.to_h))
    output = File.join(tmp_dir, 'index')
    FileUtils.mkdir_p(output)
    File.write(File.join(output, 'library.json'), JSON.generate(data))
    File.write(File.join(output, 'service.json'), JSON.generate(type: 'service', identifier: unit.identifier,
                                                                source_code: 'service control', source_hash: 'service'))
    provider = Woods::Embedding::Provider::Fake.new(dims: 4)
    vectors = Woods::Storage::VectorStore::InMemory.new
    metadata = Woods::Storage::MetadataStore::InMemory.new
    writer = Woods::Embedding::Indexer.new(provider: provider, vector_store: vectors, metadata_store: metadata,
                                           text_preparer: Woods::Embedding::TextPreparer.new, output_dir: output,
                                           chunker: nil)
    expect(writer.index_all[:processed]).to eq(3)
    artifact = Woods::IndexArtifact.new(output)
    reloaded = Woods::Storage::Snapshotter::Vector.load_or_empty(artifact)
    records = Woods::Storage::Snapshotter::Metadata.load_or_empty(artifact)
    Woods::MCP::Bootstrapper.send(:populate_vector_metadata, reloaded, records)
    lib_vectors = reloaded.each_entry.select { |_id, _vector, facts| facts[:type] == 'lib' }
    expect(lib_vectors.size).to eq(2)
    expect(lib_vectors.map { |_id, _vector, facts| facts[:file_path] }).to eq(originals.keys)
    lib_vectors.each do |_id, _vector, facts|
      expect(facts[:source_paths]).to eq(originals.keys)
      expect(facts[:physical_location][:source_sha256]).to eq(Digest::SHA256.hexdigest(originals.fetch(facts[:file_path])))
    end
    retriever = Woods::Retriever.new(vector_store: reloaded, metadata_store: records,
                                     graph_store: Woods::Storage::GraphStore::Memory.new, embedding_provider: provider)
    result = retriever.retrieve('LibraryChunks', types: %w[lib service], budget: 10_000)
    expect(result.sources.map { |source| source[:type] }).to contain_exactly('lib', 'service')
    source = result.sources.find { |entry| entry[:type] == 'lib' }
    expect(source[:source_contributors].map { |entry| entry['file_path'] }).to eq(originals.keys)
    expect(writer.index_incremental[:skipped]).to eq(2)
  end
  it 'omits unmappable spans and never substitutes the primary file during hydration' do
    facts = Woods::Chunking::ContributorChunks.vector_metadata(unit, published_location: { start_byte: 0, end_byte: 5 })
    expect(facts).to eq(source_paths: originals.keys, file_path: nil)
    metadata = { physical_location: { file_path: 'lib/a.rb' }, custom: 'retained' }
    expect(Woods::Chunking::ContributorChunks.slice_metadata(metadata, 'source', 0, 3)).to eq(custom: 'retained')
  end
end
