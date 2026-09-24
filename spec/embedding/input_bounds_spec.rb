# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'woods'
require 'woods/embedding/openai'
require 'woods/embedding/indexer'
require 'woods/embedding/text_preparer'
require 'woods/embedding/token_counter'
require 'woods/chunking/semantic_chunker'
require 'woods/storage/vector_store'

RSpec.describe 'Complete embedding input bounds' do
  let(:provider) { Woods::Embedding::Provider::OpenAI.new(api_key: 'offline', dimensions: 2) }
  let(:store) { Woods::Storage::VectorStore::InMemory.new }
  let(:requests) { [] }
  let(:unit) do
    { 'type' => 'service', 'identifier' => 'Example', 'file_path' => 'app/services/example.rb',
      'source_code' => 'class Example; end', 'source_hash' => 'unchanged', 'dependencies' => [], 'chunks' => [] }
  end

  around do |example|
    Dir.mktmpdir('woods-input-bounds') do |dir|
      @dir = dir
      example.run
    end
  end

  before do
    allow(provider).to receive(:post_request) do |body|
      texts = Array(body[:input])
      requests.concat(texts)
      { 'data' => texts.each_index.map { |i| { 'index' => i, 'embedding' => [0.2, 0.8] } } }
    end
  end

  def indexer
    Woods::Embedding::Indexer.new(provider: provider, vector_store: store, output_dir: @dir,
                                  text_preparer: Woods::Embedding::TextPreparer.new,
                                  chunker: Woods::Chunking::SemanticChunker.new)
  end

  def publish_unit
    File.write(File.join(@dir, 'example.json'), JSON.generate(unit))
  end

  it 'refuses direct oversize preparation without truncating its tail' do
    extracted = Woods::ExtractedUnit.new(type: :service, identifier: 'Example', file_path: nil)
    extracted.source_code = "#{'x' * 40_000}FINAL_SOURCE"
    expect { Woods::Embedding::TextPreparer.new.prepare(extracted) }
      .to raise_error(Woods::Error, /input.*limit/i)
  end

  it 'splits CJK inputs by the complete prefixed byte-BPE bound without losing source' do
    unit['source_code'] = "#{'漢🙂é' * 2500}FINAL_SOURCE"
    publish_unit
    indexer.index_all

    expect(requests.size).to be > 1
    expect(requests.map(&:bytesize)).to all(be <= 8191)
    contents = requests.map { |text| text.split("file: app/services/example.rb\n", 2).last }
    expect(contents.join).to eq(unit['source_code'])
  end

  it 'refuses an oversized prefix before sending or publishing any vectors' do
    unit['dependencies'] = [{ 'target' => 'PrivateDependency' * 1000 }]
    publish_unit
    expect { indexer.index_all }.to raise_error(Woods::Error, /prefix.*Example/i)
    expect(requests).to be_empty
    expect(File).not_to exist(File.join(@dir, 'checkpoint.json'))
    expect(File).not_to exist(File.join(@dir, 'dumps', 'latest'))
  end

  %w[dependencies file_path namespace].each do |field|
    it "re-embeds a changed #{field} prefix even when source_hash is unchanged" do
      publish_unit
      indexer.index_all
      requests.clear
      unit[field] = field == 'dependencies' ? [{ 'target' => 'ChangedDependency' }] : 'ChangedPrefix'
      publish_unit

      result = indexer.index_incremental
      expect(result[:processed]).to eq(1)
      expect(requests.one?).to be true
      expect(requests.first).to include('Changed')
      requests.clear
      expect(indexer.index_incremental[:skipped]).to eq(1)
      expect(requests).to be_empty
    end
  end

  it 'rejects a later oversized OpenAI input before sending the first batch' do
    expect { provider.embed_batch(Array.new(36, 'valid') + ['漢' * 10_000]) }
      .to raise_error(Woods::Error, /input.*limit/i)
    expect(requests).to be_empty
  end

  it 'makes an unknown Ollama model reject instead of silently truncating' do
    ollama = Woods::Embedding::Provider::Ollama.new(model: 'custom-model', expected_dimensions: 2)
    body = nil
    allow(ollama).to receive(:post_request) do |request|
      body = request
      { 'embeddings' => [[0.2, 0.8]] }
    end
    ollama.embed('complete source')
    expect(body).to include(truncate: false)
  end

  it 'does not download or implicitly claim a BERT tokenizer for arbitrary models' do
    tokenizer = Module.new do
      def self.from_pretrained(*)
        raise 'unexpected download'
      end
    end
    stub_const('Tokenizers', tokenizer)
    expect(tokenizer).not_to receive(:from_pretrained)
    counter = Woods::Embedding::TokenCounter.new
    allow(counter).to receive(:require).with('tokenizers').and_return(true)
    counter.count('arbitrary source')
  end

  it 'retains chunk metadata and relative byte ranges through prefix-aware splitting' do
    extracted = Woods::ExtractedUnit.new(type: :service, identifier: 'Example', file_path: 'example.rb')
    original = "#{'漢🙂' * 80}END"
    extracted.chunks = [{ content: original, metadata: { citation: { file_path: 'lib/part.rb' } },
                          custom_attribute: 'retained' }]
    budget = Woods::Embedding::InputBudget.new(limit: 100, method: 'utf8_bytes_bound')
    preparer = Woods::Embedding::TextPreparer.new
    texts = preparer.prepare_for_embedding(extracted, budget: budget)

    expect(texts.map(&:bytesize)).to all(be <= 100)
    expect(extracted.chunks.map { |chunk| chunk[:content] }.join).to eq(original)
    expect(extracted.chunks.map { |chunk| chunk[:metadata] }).to all(eq(citation: { file_path: 'lib/part.rb' }))
    expect(extracted.chunks.map { |chunk| chunk[:custom_attribute] }).to all(eq('retained'))
    extracted.chunks.each do |chunk|
      range = chunk.fetch(:embedding_slice)
      expect(original.byteslice(range[:start_byte]...range[:end_byte])).to eq(chunk[:content])
    end
  end

  it 'refuses a prefix that leaves no room for one complete Unicode character' do
    extracted = Woods::ExtractedUnit.new(type: :service, identifier: 'X', file_path: nil)
    extracted.source_code = '🙂'
    budget = Woods::Embedding::InputBudget.new(limit: "[service] X\n".bytesize + 1, method: 'utf8_bytes_bound')
    expect { Woods::Embedding::TextPreparer.new.prepare_for_embedding(extracted, budget: budget) }
      .to raise_error(Woods::Embedding::InputLimitError, /one source character/)
    expect(extracted.source_code).to eq('🙂')
  end

  it 'preserves the published dump and checkpoint after a strict server length refusal' do
    publish_unit
    indexer.index_all
    artifact = Woods::IndexArtifact.new(@dir)
    before_dump = artifact.latest_dump_path
    before_checkpoint = File.binread(File.join(@dir, 'checkpoint.json'))
    unit['namespace'] = 'ChangedInput'
    publish_unit
    allow(provider).to receive(:post_request).and_raise(
      Woods::Embedding::Provider::RequestError.new('input too long SECRET_SOURCE_MARKER', http_status: 400)
    )

    expect { indexer.index_incremental }.to raise_error(Woods::Error) { |error|
      expect(error.message).to include('HTTP 400', 'Example', 'utf8_bytes_bound', 'limit=8191')
      expect(error.full_message).not_to include('SECRET_SOURCE_MARKER')
      expect(error.cause).to be_nil
    }
    expect(artifact.latest_dump_path).to eq(before_dump)
    expect(File.binread(File.join(@dir, 'checkpoint.json'))).to eq(before_checkpoint)
  end

  it 'keeps known-model bounds through cache and retry wrappers without retrying a local refusal' do
    require 'woods/cache/cache_middleware'
    require 'woods/cache/cache_store'
    require 'woods/resilience/retryable_provider'
    wrapped = Woods::Resilience::RetryableProvider.new(provider: provider, max_retries: 2)
    cached = Woods::Cache::CachedEmbeddingProvider.new(provider: wrapped, cache_store: Woods::Cache::InMemory.new)
    expect(cached.input_budget.identity).to eq(provider.input_budget.identity)
    expect(wrapped).not_to receive(:sleep)
    expect { cached.embed('漢' * 10_000) }.to raise_error(Woods::Embedding::InputLimitError)
    expect(requests).to be_empty
  end

  it 'round-trips bounded typed chunk vectors through a dump, hydration and public retrieval' do
    require 'woods/mcp/bootstrapper'
    require 'woods/retriever'
    unit['source_code'] = '漢' * 10_000
    publish_unit
    File.write(File.join(@dir, 'same_name_model.json'), JSON.generate(unit.merge('type' => 'model')))
    writer = Woods::Embedding::Indexer.new(provider: provider, vector_store: store, output_dir: @dir,
                                           text_preparer: Woods::Embedding::TextPreparer.new,
                                           metadata_store: Woods::Storage::MetadataStore::InMemory.new)
    expect(writer.index_all[:processed]).to be > 2
    expect(requests.map(&:bytesize)).to all(be <= 8191)
    artifact = Woods::IndexArtifact.new(@dir)
    vectors = Woods::Storage::Snapshotter::Vector.load_or_empty(artifact)
    metadata = Woods::Storage::Snapshotter::Metadata.load_or_empty(artifact)
    Woods::MCP::Bootstrapper.send(:populate_vector_metadata, vectors, metadata)
    retriever = Woods::Retriever.new(vector_store: vectors, metadata_store: metadata,
                                     graph_store: Woods::Storage::GraphStore::Memory.new, embedding_provider: provider)
    result = retriever.retrieve('Explain Example', types: %w[model service], budget: 20_000)
    expect(result.sources.map { |source| source[:type] }).to contain_exactly('model', 'service')
    expect(result.sources.map { |source| source[:identifier] }.uniq).to eq(['Example'])
    expect(writer.index_incremental[:skipped]).to eq(2)
  end

  it 'keeps source-empty units vectorless even when their unused prefix is large' do
    unit['source_code'] = ''
    unit['dependencies'] = [{ 'target' => 'VeryLongDependency' * 1000 }]
    publish_unit
    expect(indexer.index_all[:processed]).to eq(0)
    expect(requests).to be_empty
    expect(indexer.index_incremental[:skipped]).to eq(1)
  end

  it 'enforces the chunk bound even below the semantic splitting threshold' do
    extracted = Woods::ExtractedUnit.new(type: :service, identifier: 'X', file_path: nil)
    extracted.source_code = '漢🙂' * 5
    chunks = Woods::Chunking::SemanticChunker.new(threshold: 200, max_chars: 3).chunk(extracted)
    expect(chunks.map(&:content).join).to eq(extracted.source_code)
    expect(chunks.map { |chunk| chunk.content.length }).to all(be <= 3)
  end
end
