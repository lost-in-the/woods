# frozen_string_literal: true

require 'spec_helper'
require 'woods'
require 'woods/builder'
require 'woods/cache/cache_middleware'

RSpec.describe 'Opt-in compact retrieval' do
  let(:store) { Woods::Storage::MetadataStore::InMemory.new }
  let(:retriever) do
    config = Woods::Configuration.new
    config.retrieval_mode = :lexical
    Woods::Builder.new(config).build_retriever(metadata_store: store)
  end
  before do
    store.store('Invoice', { identifier: 'Invoice', type: 'model', file_path: 'app/models/invoice.rb',
                             source_code: 'class Invoice; def refund(payment); payment.reverse!; end; end' })
  end

  it 'separates full, compact, and outline cached contexts and retains evidence on cache hits' do
    cached = Woods::Cache::CachedRetriever.new(retriever: retriever, cache_store: Woods::Cache::InMemory.new)
    outputs = %w[full compact outline].to_h do |mode|
      first = cached.retrieve('refund', evidence: mode)
      second = cached.retrieve('refund', evidence: mode)
      expect(second.context).to eq(first.context)
      expect(JSON.generate(second.sources)).to eq(JSON.generate(first.sources))
      [mode, first.context]
    end
    expect(outputs.values.uniq.size).to eq(3)
    expect(outputs['outline']).not_to include('payment.reverse!')
    expect(outputs['full']).not_to include('Evidence:')
  end

  it 'keeps original candidate ordering and applies scopes before compact assembly' do
    store.store('Other', { identifier: 'Other', type: 'model', file_path: 'app/other/other.rb',
                           source_code: 'class Other; def refund; end; end' })
    full = retriever.retrieve('refund')
    compact = retriever.retrieve('refund', evidence: 'compact')
    expect(compact.sources.map { |unit| unit[:identifier] }).to eq(full.sources.map { |unit| unit[:identifier] })
    scoped = retriever.retrieve('refund', evidence: 'compact', source_paths: ['app/models'])
    expect(scoped.sources.map { |unit| unit[:identifier] }).to eq(['Invoice'])
    expect(scoped.applied_scope[:eligible_units]).to eq(1)
  end

  it 'rejects invalid evidence before invoking a provider or searching stores' do
    expect(retriever.pipeline.executor).not_to receive(:execute)
    expect { retriever.retrieve('refund', evidence: 'guess') }.to raise_error(ArgumentError, /evidence/)
  end
  it 'passes the query through semantic ranking and assembly without changing full output' do
    vector = Woods::Storage::VectorStore::InMemory.new
    vector.store('Invoice', [1.0, 0.0], { type: 'model' })
    graph = Woods::Storage::GraphStore::Memory.new
    semantic = Woods::Retriever.new(metadata_store: store, vector_store: vector, graph_store: graph,
                                    embedding_provider: double('provider', embed: [1.0, 0.0]))
    ordinary = semantic.retrieve('How do refunds work?')
    expect(semantic.retrieve('How do refunds work?', evidence: 'full').context).to eq(ordinary.context)
    result = semantic.retrieve('How do refunds work?', evidence: 'compact', budget: 800)
    expect(result.context).to include('payment.reverse!')
    expect(result.sources.first[:evidence]).to include(mode: 'compact', generation_status: 'unavailable')
    expect(result.trace.ranked_count).to eq(ordinary.trace.ranked_count)
  end
  it 'retains the fixed target method that full assembly loses at the identical budget' do
    prefix = (1..80).map { |i| "def unrelated_#{i}; #{'nil; ' * 25}end\n" }.join
    method = "def refund(payment)\n payment.reverse!\nend"
    store.store('Invoice', { identifier: 'Invoice', type: 'model', file_path: 'app/models/invoice.rb',
                             source_code: "class Invoice\n#{prefix}#{method}\nend" })
    full = retriever.retrieve('refund payment', evidence: 'full', budget: 450)
    compact = retriever.retrieve('refund payment', evidence: 'compact', budget: 450)
    expect(full.context).not_to include(method)
    expect(compact.context).to include(method)
    expect([full.tokens_used, compact.tokens_used]).to all(be <= 450)
  end
end
