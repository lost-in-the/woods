# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'woods'
require 'woods/embedding/indexer'

# #178 — the end-to-end that used to be impossible without a live network
# endpoint: embed a unit set with the deterministic :fake provider, then
# retrieve against the same Builder-resolved stack and get relevant
# results. Everything below runs offline — no Ollama, no OpenAI, no Rails.
RSpec.describe 'Embed → retrieve round trip with the :fake provider', :integration do
  let(:fixture_hashes) { load_fixture_units }
  let(:output_dir) { Dir.mktmpdir('woods_fake_round_trip') }

  let(:config) do
    Woods::Configuration.new.tap do |c|
      c.embedding_provider = :fake
      c.embedding_options = { dims: 64 }
      c.vector_store = :in_memory
      c.metadata_store = :in_memory
      c.graph_store = :in_memory
    end
  end

  let(:builder) { Woods::Builder.new(config) }
  # Shared between the indexer (writer) and retriever (reader) — the same
  # sharing Builder#build_retriever's injection kwargs exist for.
  let(:vector_store) { builder.build_vector_store }
  let(:metadata_store) { builder.build_metadata_store }

  before do
    fixture_hashes.each do |unit_hash|
      type_dir = File.join(output_dir, "#{unit_hash['type']}s")
      FileUtils.mkdir_p(type_dir)
      File.write(File.join(type_dir, "#{unit_hash['identifier']}.json"), JSON.generate(unit_hash))
    end
  end

  after { FileUtils.rm_rf(output_dir) }

  it 'embeds offline and retrieves relevant units through the same configured stores' do
    provider = builder.build_embedding_provider
    indexer = Woods::Embedding::Indexer.new(
      provider: builder.build_resilient_embedding_provider(provider),
      text_preparer: builder.build_text_preparer(provider),
      chunker: builder.build_chunker(provider),
      vector_store: vector_store,
      metadata_store: metadata_store,
      output_dir: output_dir
    )

    stats = indexer.index_all
    expect(stats[:processed]).to eq(fixture_hashes.size)
    expect(stats[:errors]).to eq(0)
    expect(vector_store.count).to be >= fixture_hashes.size

    retriever = builder.build_retriever(
      vector_store: vector_store,
      metadata_store: metadata_store,
      graph_store: builder.build_graph_store
    )

    result = retriever.retrieve('How does the User model work?', budget: config.max_context_tokens)

    expect(result.sources).not_to be_empty
    expect(result.sources.map { |s| s[:identifier] }).to include('User')
    expect(result.context).not_to be_empty
  end
end
