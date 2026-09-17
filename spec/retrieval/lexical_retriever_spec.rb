# frozen_string_literal: true

require 'spec_helper'
require 'woods'
require 'woods/builder'
require 'woods/storage_identity'
require 'woods/cache/cache_middleware'

RSpec.describe 'Explicit lexical retrieval' do
  let(:config) { Woods::Configuration.new }
  let(:store) { Woods::Storage::MetadataStore::InMemory.new }
  let(:builder) { Woods::Builder.new(config) }

  before do
    store.store(Woods::StorageIdentity.key('Delivery', 'service'), {
                  'identifier' => 'Delivery', 'type' => 'service', 'file_path' => 'app/services/delivery.rb',
                  'source_code' => 'def notify; send_email; end', 'metadata' => {}
                })
  end

  it 'defaults to semantic and validates explicit modes' do
    expect(config.retrieval_mode).to eq(:semantic)
    config.retrieval_mode = 'lexical'
    expect(config.retrieval_mode).to eq(:lexical)
    expect { config.retrieval_mode = :other }.to raise_error(Woods::ConfigurationError)
  end

  it 'builds and retrieves without constructing providers or vectors' do
    config.retrieval_mode = :lexical
    expect(builder).not_to receive(:build_resilient_embedding_provider)
    expect(builder).not_to receive(:build_vector_store)
    retriever = builder.build_retriever(metadata_store: store)
    result = retriever.retrieve('How do we send email?', types: ['service'])
    expect(result.strategy).to eq(:lexical)
    expect(result.sources.first[:identifier]).to eq('Delivery')
    expect(result.sources.first[:matched_fields]).to include('source_code:email')
    expect(result.context).to include('Mode: lexical', 'source_code:email')
    expect(result.tokens_used).to be <= result.budget
  end

  it 'renders the published runtime values that justified a metadata-only match' do
    store.store('Record', { 'identifier' => 'Record', 'type' => 'model', 'source_code' => '',
                            'metadata' => { 'callbacks' => { 'before_save' => ['normalize_phone'] } } })
    config.retrieval_mode = :lexical
    result = builder.build_retriever(metadata_store: store).retrieve('normalize phone')
    expect(result.context).to include('before_save', 'normalize_phone')
  end

  it 'keeps no match observable and honors tiny estimated budgets including notices' do
    config.retrieval_mode = :lexical
    retriever = builder.build_retriever(metadata_store: store)
    expect(retriever.retrieve('unfindable').context).to include('No lexical matches')
    [1, 10, 40, 80, 200].each do |budget|
      result = retriever.retrieve('email', budget: budget)
      expect(result.tokens_used).to be <= budget
      expect(result.context.length).to be <= budget * 4
    end
  end

  it 'separates lexical contexts from semantic entries in a shared cache' do
    config.retrieval_mode = :lexical
    lexical = builder.build_retriever(metadata_store: store)
    cache = Woods::Cache::InMemory.new
    semantic = double('semantic retriever', mode: :semantic)
    expected = Woods::Retriever::RetrievalResult.new(context: 'semantic answer', sources: [], strategy: :vector)
    allow(semantic).to receive(:retrieve).and_return(expected)
    Woods::Cache::CachedRetriever.new(retriever: semantic, cache_store: cache).retrieve('email')
    cached = Woods::Cache::CachedRetriever.new(retriever: lexical, cache_store: cache)
    first = cached.retrieve('email')
    second = cached.retrieve('email')
    expect(first.strategy).to eq(:lexical)
    expect(second.strategy).to eq(:lexical)
    expect(second.context).to eq(first.context)
    expect(second.context).to include('source_code:email')
  end

  it 'atomically replaces the immutable lexical pipeline' do
    config.retrieval_mode = :lexical
    retriever = builder.build_retriever(metadata_store: store)
    replacement = Woods::Storage::MetadataStore::InMemory.new
    captured = nil
    retriever.pipeline_observer = lambda do |pipeline|
      captured = pipeline
      retriever.swap_stores!(vector_store: nil, metadata_store: replacement, graph_store: nil)
    end
    expect(retriever.retrieve('email').sources.size).to eq(1)
    expect(captured).not_to equal(retriever.pipeline)
    retriever.pipeline_observer = nil
    expect(retriever.retrieve('email').sources).to be_empty
  end
end
