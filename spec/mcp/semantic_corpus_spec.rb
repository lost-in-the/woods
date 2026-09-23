# frozen_string_literal: true

require 'spec_helper'
require 'woods'
require 'woods/mcp/bootstrapper'
require 'woods/mcp/server'
require 'woods/cache/cache_middleware'
require 'woods/cache/cache_store'
require 'tmpdir'
require 'fileutils'

RSpec.describe 'semantic corpus diagnostics' do
  include_context 'isolated Woods runtime'

  let(:provider) { Woods::Embedding::Provider::Fake.new(dims: 4) }
  let(:vectors) { Woods::Storage::VectorStore::InMemory.new }
  let(:metadata) { Woods::Storage::MetadataStore::InMemory.new }
  let(:graph) { Woods::Storage::GraphStore::Memory.new }
  let(:retriever) do
    Woods::Retriever.new(vector_store: vectors, metadata_store: metadata,
                         graph_store: graph, embedding_provider: provider)
  end
  let(:reader) { Woods::MCP::IndexReader.new(@index) }
  let(:state) { nil }

  around do |example|
    Dir.mktmpdir('woods-corpus') do |dir|
      @index = File.join(dir, 'index')
      FileUtils.cp_r(File.expand_path('../fixtures/woods', __dir__), @index)
      example.run
    end
  end

  def status(target = retriever, bootstrap = state)
    Woods::MCP::Server.build_status(reader: reader, retriever: target, index_dir: @index, bootstrap_state: bootstrap)
  end

  def retrieve(target = retriever, bootstrap = state, query: 'Post')
    server = Woods::MCP::Server.build(index_dir: @index, retriever: target, bootstrap_state: bootstrap,
                                      response_format: :json)
    server.instance_variable_get(:@tools).fetch('codebase_retrieve').call(query: query, server_context: {})
  end

  def add_metadata(store = metadata)
    store.store('Post', type: 'model', identifier: 'Post', source_code: 'class Post; def publish; end; end',
                        file_path: 'app/models/post.rb')
  end

  it 'keeps structural readiness while reporting an empty semantic corpus' do
    expect(status[:ready]).to be(true)
    expect(status.dig(:index, :total_units)).to eq(9)
    expect(status.dig(:retriever, :corpus)).to eq(
      state: 'empty',
      vectors: { count: 0, by_type: {}, untyped_count: 0 },
      metadata: { count: 0, by_type: {}, untyped_count: 0 }
    )
  end

  it 'diagnoses two empty stores before calling the embedding provider' do
    expect(provider).not_to receive(:embed)
    response = retrieve(query: 'How does publishing work?')

    expect(response.error?).to be(true)
    expect(response.meta[:error_code]).to eq(:empty_index)
    expect(response.content.first[:text]).to include('woods:embed', 'WOODS_RETRIEVAL_MODE=lexical')
  end

  { keyword: 'Find Post', direct: 'Find exactly Post' }.each do |strategy, query|
    it "preserves metadata-only #{strategy} retrieval without embedding the query" do
      add_metadata
      expect(provider).not_to receive(:embed)
      expect(status.dig(:retriever, :corpus, :state)).to eq('metadata_only')
      expect(retriever).to receive(:retrieve).and_wrap_original do |original, *args, **kwargs|
        original.call(*args, **kwargs).tap { |result| expect(result.strategy).to eq(strategy) }
      end
      response = retrieve(query: query)

      expect(response.error?).to be(false)
      expect(response.content.first[:text]).to include('def publish')
    end
  end

  it 'reports vectors without metadata without replacing the stale-index diagnosis' do
    vectors.store('Post', [1, 0, 0, 0], type: 'model')
    expect(status.dig(:retriever, :corpus, :state)).to eq('vectors_only')
    response = retrieve(query: 'How does publishing work?')

    expect(response.error?).to be(true)
    expect(response.meta[:error_code]).to eq(:stale_index)
  end

  it 'counts vector chunks and source-empty metadata separately without requiring equal totals' do
    add_metadata
    metadata.store('Empty', type: 'service', source_code: '')
    3.times { |i| vectors.store("Post#chunk_#{i}", [1, 0, 0, 0], 'type' => 'model') }

    corpus = status.dig(:retriever, :corpus)
    expect(corpus[:state]).to eq('nonempty')
    expect(corpus[:vectors]).to eq(count: 3, by_type: { 'model' => 3 }, untyped_count: 0)
    expect(corpus[:metadata]).to eq(count: 2, by_type: { 'model' => 1, 'service' => 1 }, untyped_count: 0)
    result = retriever.retrieve('Find Post', types: ['model'])
    expect(result.context).to include('Retrieval metadata records')
    expect(result.type_rank_context['model'][:total_of_type]).to eq(1)
  end

  it 'does not infer a type for untyped entries or count deleted vectors' do
    vectors.store('Post', [1, 0, 0, 0], type: 'model')
    vectors.store('Unknown', [1, 0, 0, 0])
    vectors.delete('Post')
    metadata.store('Unknown', {})

    expect(status.dig(:retriever, :corpus, :vectors)).to eq(count: 1, by_type: {}, untyped_count: 1)
    expect(status.dig(:retriever, :corpus, :metadata)).to eq(count: 1, by_type: {}, untyped_count: 1)
  end

  it 'keeps remote and unsupported counts unknown without asking the adapter for data' do
    remote = double('RemoteVectorStore')
    expect(remote).not_to receive(:count)
    expect(remote).not_to receive(:each_entry)
    expect(remote).not_to receive(:each_id)
    target = Woods::Retriever.new(vector_store: remote, metadata_store: metadata,
                                  graph_store: graph, embedding_provider: provider)

    expect(status(target).dig(:retriever, :corpus)).to include(
      state: 'unknown', vectors: { count: nil, by_type: nil, untyped_count: nil }
    )
    expect(target).to receive(:retrieve).and_return(Woods::Retriever::RetrievalResult.new(context: '', sources: []))
    expect(retrieve(target).error?).to be(false)
  end

  it 'reports local diagnostic failures as unknown rather than zero' do
    allow(vectors).to receive(:local_corpus_stats).and_raise(IOError, 'unreadable')
    expect(status.dig(:retriever, :corpus)).to include(
      state: 'unknown', vectors: { count: nil, by_type: nil, untyped_count: nil }
    )
  end

  it 'reads local SQLite metadata totals by type without requiring vectors' do
    sqlite = Woods::Storage::MetadataStore::SQLite.new(database: File.join(@index, 'metadata.sqlite3'))
    add_metadata(sqlite)
    target = Woods::Retriever.new(vector_store: vectors, metadata_store: sqlite,
                                  graph_store: graph, embedding_provider: provider)

    expect(status(target).dig(:retriever, :corpus)).to include(
      state: 'metadata_only', metadata: { count: 1, by_type: { 'model' => 1 }, untyped_count: 0 }
    )
  end

  it 'keeps SQLite diagnostic query failures unknown instead of reporting an empty corpus' do
    sqlite = Woods::Storage::MetadataStore::SQLite.new(database: File.join(@index, 'metadata.sqlite3'))
    sqlite.instance_variable_get(:@db).close
    target = Woods::Retriever.new(vector_store: vectors, metadata_store: sqlite,
                                  graph_store: graph, embedding_provider: provider)

    expect(status(target).dig(:retriever, :corpus)).to include(
      state: 'unknown', metadata: { count: nil, by_type: nil, untyped_count: nil }
    )
    expect(target).to receive(:retrieve).and_return(Woods::Retriever::RetrievalResult.new(context: '', sources: []))
    expect(retrieve(target).error?).to be(false)
  end

  it 'leaves lexical retrieval independent of vector availability' do
    target = Woods::MCP::PublishedLexicalRetriever.new(index_dir: @index)
    expect(status(target)[:retriever]).not_to have_key(:corpus)
    response = retrieve(target)

    expect(response.error?).to be(false)
    expect(response.content.first[:text]).to include('Post')
  end

  it 'preserves hydration failure precedence over the empty-corpus diagnosis' do
    bootstrap = Woods::MCP::BootstrapState.new
    bootstrap.record_hydration_failure(:vector, IOError.new('unreadable dump'))
    bootstrap.mark(:degraded)

    expect(retrieve(retriever, bootstrap).meta[:error_code]).to eq(:degraded_index)
  end

  it 'reports provider degradation separately from an empty corpus' do
    bootstrap = Woods::MCP::BootstrapState.new
    bootstrap.mark(:degraded, reason: Woods::MCP::ProviderUnreachable.new(url: 'http://localhost', reason: 'offline'))

    expect(status(retriever, bootstrap).dig(:bootstrap, :status)).to eq(:degraded)
    expect(status(retriever, bootstrap).dig(:retriever, :corpus, :state)).to eq('empty')
  end

  [true, false].each do |configured|
    it "reports empty stores for #{configured ? 'configured' : 'autodetected'} Ollama without embedding artifacts" do
      Woods.configuration.embedding_provider = :ollama if configured
      Woods.configuration.vector_store = :in_memory
      Woods.configuration.metadata_store = :in_memory
      Woods.configuration.graph_store = :in_memory
      allow(Woods::MCP::Bootstrapper).to receive(:ollama_reachable?).and_return(true)
      allow_any_instance_of(Woods::Builder).to receive(:build_embedding_provider).and_return(provider)
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with('OPENAI_API_KEY').and_return(nil)
      allow(ENV).to receive(:[]).with('WOODS_REQUIRE_INDEX').and_return(nil)
      expect(Net::HTTP).not_to receive(:start)
      target, bootstrap = nil

      expect do
        target, bootstrap = Woods::MCP::Bootstrapper.build_retriever(index_dir: @index)
      end.to output(/hydrated \(ollama\); corpus: empty/).to_stderr
      expect(bootstrap.status).to eq(:hydrated)
      expect(status(target, bootstrap).dig(:retriever, :corpus, :state)).to eq('empty')
      expect(retrieve(target, bootstrap).meta[:error_code]).to eq(:empty_index)
    end
  end

  it 'updates cached retriever diagnostics and retrieval after a real dump reload' do
    Woods.configuration.embedding_provider = :fake
    Woods.configuration.embedding_options = { dims: 4 }
    Woods.configuration.vector_store = :in_memory
    Woods.configuration.metadata_store = :in_memory
    Woods.configuration.graph_store = :in_memory
    cached = Woods::Cache::CachedRetriever.new(retriever: retriever, cache_store: Woods::Cache::InMemory.new)
    expect(status(cached).dig(:retriever, :corpus, :state)).to eq('empty')
    expect(retrieve(cached).meta[:error_code]).to eq(:empty_index)

    source_vectors = Woods::Storage::VectorStore::InMemory.new
    source_metadata = Woods::Storage::MetadataStore::InMemory.new
    source_vectors.store('Post', [1, 0, 0, 0], type: 'model')
    add_metadata(source_metadata)
    artifact = Woods::IndexArtifact.new(@index)
    resolved = Woods::ResolvedConfig.from_configuration(Woods.configuration, provider: provider)
    dump = artifact.new_dump_dir
    Woods::Storage::Snapshotter::Vector.dump(source_vectors, artifact, dump, resolved_config: resolved)
    Woods::Storage::Snapshotter::Metadata.dump(source_metadata, artifact, dump, resolved_config: resolved)
    artifact.write_config(resolved.to_snapshot_json)
    artifact.promote(dump)
    Woods::MCP::Bootstrapper.reload_stores!(cached, index_dir: @index, reader: reader)

    expect(status(cached).dig(:retriever, :corpus, :state)).to eq('nonempty')
    expect(retrieve(cached).content.first[:text]).to include('def publish')
  end
end
