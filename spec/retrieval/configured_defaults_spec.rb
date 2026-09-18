# frozen_string_literal: true

require 'spec_helper'
require 'woods'
require 'woods/builder'
require 'woods/mcp/bootstrapper'
require 'woods/mcp/server'

RSpec.describe 'Configured retrieval defaults' do
  let(:config) do
    Woods::Configuration.new.tap do |value|
      value.embedding_provider = :fake
      value.embedding_options = { dims: 8 }
      value.max_context_tokens = 1
      value.cache_store = :memory
    end
  end
  let(:metadata) do
    Woods::Storage::MetadataStore::InMemory.new.tap do |store|
      store.store('Invoice', { identifier: 'Invoice', type: 'model', file_path: 'app/models/invoice.rb',
                               source_code: 'class Invoice; def refund; payments.each(&:refund); end; end',
                               dependencies: [] })
    end
  end
  let(:vectors) do
    Woods::Storage::VectorStore::InMemory.new.tap do |store|
      provider = Woods::Embedding::Provider::Fake.new(dims: 8)
      store.store('Invoice', provider.embed('Invoice refund'), type: 'model', identifier: 'Invoice')
    end
  end
  let(:graph) { Woods::Storage::GraphStore::Memory.new }
  let(:fixture_dir) { File.expand_path('../fixtures/woods', __dir__) }

  def build
    Woods::Builder.new(config).build_retriever(vector_store: vectors, metadata_store: metadata, graph_store: graph)
  end

  %i[semantic lexical].each do |mode|
    [false, true].each do |cached|
      it "uses configured defaults with explicit override precedence in #{mode}, cached=#{cached}" do
        config.retrieval_mode = mode
        config.cache_enabled = cached
        retriever = build
        small = retriever.retrieve('Invoice refund')
        expect(small.budget).to eq(1)
        expect(small.context).not_to include('Invoice')
        large = retriever.retrieve('Invoice refund', budget: 512)
        expect(large.budget).to eq(512)
        expect(large.context).to include('Invoice')
        expect(large.tokens_used).to be > small.tokens_used
        expect(retriever.retrieve('Invoice refund').context).to eq(small.context)
        expect(retriever.retrieve('Invoice refund', budget: 1).context).to eq(small.context)
        config.max_context_tokens = 512
        expect(retriever.retrieve('Invoice refund').budget).to eq(1)
      end
    end
  end

  it 'keys cached omitted and explicit default budgets identically, separating another configured default' do
    cache = Woods::Cache::InMemory.new
    config.cache_enabled = true
    config.cache_store = cache
    keys = []
    allow(cache).to receive(:read).and_wrap_original do |method, key|
      keys << key if key.start_with?('woods:cache:context:')
      method.call(key)
    end
    small = build
    small.retrieve('Invoice refund')
    small.retrieve('Invoice refund', budget: 1)
    config.max_context_tokens = 512
    large = build
    expect(large.retrieve('Invoice refund').budget).to eq(512)
    expect(keys[0]).to eq(keys[1])
    expect(keys[2]).not_to eq(keys[0])
  end

  def mcp_call(retriever, **arguments)
    result = nil
    allow(retriever).to receive(:retrieve).and_wrap_original do |method, *args, **options|
      result = method.call(*args, **options)
    end
    server = Woods::MCP::Server.build(index_dir: fixture_dir, retriever: retriever,
                                      response_format: :json, warmup: false)
    response = server.handle_json(JSON.generate(jsonrpc: '2.0', id: 1, method: 'tools/call',
                                                params: { name: 'codebase_retrieve', arguments: arguments }))
    body = JSON.parse(response)
    expect(body.fetch('result')['isError']).not_to be(true)
    expect(body.fetch('result').fetch('structuredContent').fetch('text')).to eq(result.context)
    result
  end

  it 'uses the configured builder default at MCP and preserves explicit tool budgets' do
    retriever = build
    expect(mcp_call(retriever, query: 'Invoice refund').budget).to eq(1)
    expect(mcp_call(retriever, query: 'Invoice refund', budget: 512).budget).to eq(512)
  end

  it 'uses configured defaults for packaged lexical bootstrap and MCP' do
    Woods.configuration = config
    config.retrieval_mode = :lexical
    retriever, = Woods::MCP::Bootstrapper.build_retriever(index_dir: fixture_dir)
    expect(retriever.retrieve('publish').budget).to eq(1)
    expect(mcp_call(retriever, query: 'publish').budget).to eq(1)
    expect(mcp_call(retriever, query: 'publish', budget: 512).budget).to eq(512)
  end

  it 'retains the 8000-token fallback for custom MCP collaborators requiring the budget keyword' do
    custom = Object.new
    def custom.retrieve(_query, budget:, **_options)
      Woods::Retriever::RetrievalResult.new(context: '', sources: [], strategy: :vector, tokens_used: 0, budget: budget)
    end
    expect(mcp_call(custom, query: 'Invoice').budget).to eq(8000)
    expect(mcp_call(custom, query: 'Invoice', budget: 500).budget).to eq(500)
  end

  it 'warns when setting the inert threshold without changing returned scores or candidates' do
    config.max_context_tokens = 512
    expect { config.similarity_threshold = 0 }.to output(/similarity_threshold.*deprecated.*does not filter/).to_stderr
    low = build.retrieve('Invoice refund')
    expect { config.similarity_threshold = 1 }.to output(/similarity_threshold.*deprecated.*does not filter/).to_stderr
    high = build.retrieve('Invoice refund')
    expect(low.sources).not_to be_empty
    expect(high.sources).to eq(low.sources)
    expect(high.context).to eq(low.context)
  end
end
