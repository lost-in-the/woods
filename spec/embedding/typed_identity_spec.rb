# frozen_string_literal: true

require 'spec_helper'
require 'woods'
require 'woods/embedding/indexer'
require 'woods/embedding/text_preparer'
require 'woods/storage/vector_store'
require 'woods/storage/metadata_store'
require 'woods/retriever'

RSpec.describe 'Typed embedding identities' do
  it 'retains both types through incremental embedding and retrieval' do
    Dir.mktmpdir do |dir|
      provider = Object.new
      def provider.embed_batch(texts) = texts.map { [1.0, 0.0] }
      def provider.embed(_text) = [1.0, 0.0]
      vectors = Woods::Storage::VectorStore::InMemory.new
      metadata = Woods::Storage::MetadataStore::InMemory.new
      indexer = Woods::Embedding::Indexer.new(provider: provider, text_preparer: Woods::Embedding::TextPreparer.new,
                                              vector_store: vectors, metadata_store: metadata, output_dir: dir)
      %w[factory database_view].each_with_index do |type, index|
        data = { type: type, identifier: 'reports', source_code: "#{type} reports",
                 source_hash: type, dependencies: [], chunks: [] }
        File.write(File.join(dir, "#{type}.json"), JSON.generate(data))
        index.zero? ? indexer.index_all : indexer.index_incremental
      end
      expect(vectors.count).to eq(2)
      expect(metadata.count).to eq(2)
      retriever = Woods::Retriever.new(vector_store: vectors, metadata_store: metadata,
                                       graph_store: Woods::Storage::GraphStore::Memory.new,
                                       embedding_provider: provider)
      result = retriever.retrieve('Explain reports', types: %w[factory database_view])
      expect(result.sources.map { |s| s[:type] }).to contain_exactly('factory', 'database_view')
      expect(result.sources.map { |s| s[:identifier] }.uniq).to eq(['reports'])
      expect(indexer.index_incremental[:skipped]).to eq(2)
      artifact = Woods::IndexArtifact.new(dir)
      reloaded = Woods::Storage::Snapshotter::Metadata.load_or_empty(artifact)
      expect(reloaded.count).to eq(2)
      3.times do |index|
        data = { type: 'service', identifier: "Other#{index}", source_code: 'other', source_hash: 'other' }
        File.write(File.join(dir, "other#{index}.json"), JSON.generate(data))
      end
      indexer.index_incremental
      File.delete(File.join(dir, 'factory.json'))
      indexer.index_incremental
      expect(vectors.count).to eq(4)
      expect(metadata.count).to eq(4)
      expect(metadata.search('reports').map { |record| record['type'] }).to eq(['database_view'])
    end
  end
end
