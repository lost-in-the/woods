# frozen_string_literal: true

require 'spec_helper'
require 'codebase_index/storage/vector_store'
require 'codebase_index/storage/metadata_store'
require 'codebase_index/storage/graph_store'

RSpec.describe 'Storage adapters working together', :integration do
  let(:fixture_hashes) { load_fixture_units }
  let(:units) { fixture_hashes.map { |h| build_extracted_unit(h) } }
  let(:vector_store) { CodebaseIndex::Storage::VectorStore::InMemory.new }
  let(:metadata_store) { CodebaseIndex::Storage::MetadataStore::SQLite.new(':memory:') }
  let(:graph_store) { CodebaseIndex::Storage::GraphStore::Memory.new }
  let(:provider) { CodebaseIndex::Embedding::Provider::Fake.new(dims: 64) }

  before do
    populate_stores(units, vector_store: vector_store, metadata_store: metadata_store,
                           graph_store: graph_store, provider: provider)
  end

  describe 'MetadataStore::SQLite' do
    it 'stores and retrieves all fixture units' do
      expect(metadata_store.count).to eq(units.size)

      units.each do |unit|
        record = metadata_store.find(unit.identifier)
        expect(record).not_to be_nil
        expect(record['type']).to eq(unit.type.to_s)
        expect(record['identifier']).to eq(unit.identifier)
      end
    end

    it 'finds units by type' do
      models = metadata_store.find_by_type('model')
      expect(models.size).to eq(3)
      expect(models.map { |m| m['id'] }).to contain_exactly('User', 'Post', 'Comment')
    end

    it 'searches across metadata fields' do
      results = metadata_store.search('user_mailer.rb')
      expect(results.any? { |r| r['id'] == 'UserMailer' }).to be true
    end

    it 'searches specific fields' do
      results = metadata_store.search('User', fields: ['identifier'])
      identifiers = results.map { |r| r['id'] }
      expect(identifiers).to include('User')
    end

    it 'supports upsert semantics' do
      metadata_store.store('User', { type: 'model', identifier: 'User', updated: true })
      record = metadata_store.find('User')
      expect(record['updated']).to be true
      expect(metadata_store.count).to eq(units.size)
    end

    it 'deletes by id' do
      metadata_store.delete('Comment')
      expect(metadata_store.find('Comment')).to be_nil
      expect(metadata_store.count).to eq(units.size - 1)
    end
  end

  describe 'VectorStore::InMemory' do
    it 'stores vectors for all units' do
      expect(vector_store.count).to eq(units.size)
    end

    it 'searches by vector similarity' do
      query = provider.embed('class User has_many posts validates email')
      results = vector_store.search(query, limit: 3)

      expect(results.size).to eq(3)
      expect(results.first.score).to be > 0.0
    end

    it 'filters results by metadata' do
      query = provider.embed('controller action')
      results = vector_store.search(query, limit: 10, filters: { type: 'controller' })

      expect(results).not_to be_empty
      results.each do |r|
        expect(r.metadata[:type]).to eq('controller')
      end
    end

    it 'deletes by id' do
      vector_store.delete('User')
      expect(vector_store.count).to eq(units.size - 1)

      query = provider.embed('User model')
      results = vector_store.search(query, limit: 10)
      expect(results.map(&:id)).not_to include('User')
    end

    it 'deletes by filter' do
      vector_store.delete_by_filter(type: 'model')
      expect(vector_store.count).to eq(units.size - 3)
    end
  end

  describe 'GraphStore::Memory' do
    it 'tracks dependencies between units' do
      user_deps = graph_store.dependencies_of('User')
      expect(user_deps).to include('Post')
      expect(user_deps).to include('Comment')
      expect(user_deps).to include('UserMailer')
    end

    it 'tracks reverse dependencies' do
      user_dependents = graph_store.dependents_of('User')
      expect(user_dependents).to include('Post')
      expect(user_dependents).to include('Comment')
      expect(user_dependents).to include('UsersController')
    end

    it 'finds units by type' do
      models = graph_store.by_type(:model)
      expect(models).to contain_exactly('User', 'Post', 'Comment')

      controllers = graph_store.by_type(:controller)
      expect(controllers).to contain_exactly('UsersController', 'PostsController')
    end

    it 'computes affected_by for file changes' do
      affected = graph_store.affected_by(['app/models/user.rb'])
      expect(affected).to include('User')
    end

    it 'computes pagerank scores' do
      scores = graph_store.pagerank
      expect(scores).not_to be_empty

      # User should have high rank — many things depend on it
      expect(scores['User']).to be > 0.0
    end
  end

  describe 'cross-store queries' do
    it 'finds similar vectors then enriches with metadata' do
      query = provider.embed('class User validates email has_many posts')
      vector_results = vector_store.search(query, limit: 3)

      enriched = vector_results.map do |result|
        metadata = metadata_store.find(result.id)
        { id: result.id, score: result.score, metadata: metadata }
      end

      expect(enriched.size).to eq(3)
      enriched.each do |item|
        expect(item[:metadata]).not_to be_nil
        expect(item[:score]).to be > 0.0
      end
    end

    it 'finds by type in metadata then gets graph relationships' do
      models = metadata_store.find_by_type('model')
      model_ids = models.map { |m| m['id'] }

      relationships = model_ids.to_h do |id|
        [id, {
          dependencies: graph_store.dependencies_of(id),
          dependents: graph_store.dependents_of(id)
        }]
      end

      expect(relationships['User'][:dependencies]).to include('Post')
      expect(relationships['Post'][:dependencies]).to include('User')
    end

    it 'uses graph to expand vector search results' do
      query = provider.embed('user registration service')
      results = vector_store.search(query, limit: 1)
      top_id = results.first.id

      # Expand to include dependencies
      deps = graph_store.dependencies_of(top_id)
      all_ids = [top_id] + deps

      expanded = all_ids.filter_map { |id| metadata_store.find(id) }
      expect(expanded.size).to be >= 1
    end

    it 'uses pagerank to rerank vector search results' do
      query = provider.embed('model controller service')
      results = vector_store.search(query, limit: 8)
      scores = graph_store.pagerank

      scored = results.map do |r|
        importance = scores[r.id] || 0.0
        combined = (r.score * 0.7) + (importance * 0.3 * 100)
        { id: r.id, vector_score: r.score, importance: importance, combined: combined }
      end
      reranked = scored.sort_by { |r| -r[:combined] }

      expect(reranked.size).to eq(results.size)
      expect(reranked.first[:combined]).to be > 0.0
    end
  end
end
