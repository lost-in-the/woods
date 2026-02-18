# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'codebase_index/chunking/semantic_chunker'
require 'codebase_index/embedding/text_preparer'
require 'codebase_index/embedding/indexer'
require 'codebase_index/storage/vector_store'

RSpec.describe 'Chunking → Embedding → Storage pipeline', :integration do
  let(:fixture_hashes) { load_fixture_units }
  let(:units) { fixture_hashes.map { |h| build_extracted_unit(h) } }
  let(:chunker) { CodebaseIndex::Chunking::SemanticChunker.new(threshold: 50) }
  let(:preparer) { CodebaseIndex::Embedding::TextPreparer.new(max_tokens: 8192) }
  let(:provider) { CodebaseIndex::Embedding::Provider::Fake.new(dims: 64) }
  let(:vector_store) { CodebaseIndex::Storage::VectorStore::InMemory.new }

  describe 'SemanticChunker processes all unit types' do
    it 'produces chunks for each unit with source code' do
      units.each do |unit|
        chunks = chunker.chunk(unit)
        expect(chunks).not_to be_empty, "Expected chunks for #{unit.identifier}"
        chunks.each do |chunk|
          expect(chunk.parent_identifier).to eq(unit.identifier)
          expect(chunk.content).not_to be_empty
        end
      end
    end

    it 'chunks models into semantic sections' do
      user_unit = units.find { |u| u.identifier == 'User' }
      chunks = chunker.chunk(user_unit)

      chunk_types = chunks.map(&:chunk_type)
      expect(chunk_types).to include(:associations)
      expect(chunk_types).to include(:validations)
      expect(chunk_types).to include(:callbacks)
      expect(chunk_types).to include(:methods)
    end

    it 'chunks controllers into summary and actions' do
      posts_controller = units.find { |u| u.identifier == 'PostsController' }
      chunks = chunker.chunk(posts_controller)

      chunk_types = chunks.map(&:chunk_type)
      expect(chunk_types).to include(:summary)
      expect(chunk_types.any? { |t| t.to_s.start_with?('action_') }).to be true
    end

    it 'returns whole chunks for small units' do
      large_chunker = CodebaseIndex::Chunking::SemanticChunker.new(threshold: 100_000)
      comment_unit = units.find { |u| u.identifier == 'Comment' }
      chunks = large_chunker.chunk(comment_unit)

      expect(chunks.size).to eq(1)
      expect(chunks.first.chunk_type).to eq(:whole)
    end
  end

  describe 'TextPreparer adds context prefixes' do
    it 'prepares text with type and identifier header' do
      user_unit = units.find { |u| u.identifier == 'User' }
      text = preparer.prepare(user_unit)

      expect(text).to include('[model] User')
      expect(text).to include('file: app/models/user.rb')
      expect(text).to include('dependencies: Post, Comment')
    end

    it 'prepares chunked text for units with chunks' do
      user_unit = units.find { |u| u.identifier == 'User' }
      chunks = chunker.chunk(user_unit)
      user_unit.chunks = chunks.map(&:to_h)

      texts = preparer.prepare_chunks(user_unit)
      expect(texts.size).to eq(chunks.size)
      texts.each do |text|
        expect(text).to include('[model] User')
      end
    end
  end

  describe 'FakeEmbeddingProvider produces meaningful vectors' do
    it 'returns vectors of the configured dimension' do
      vec = provider.embed('class User < ApplicationRecord; end')
      expect(vec.size).to eq(64)
    end

    it 'returns normalized vectors' do
      vec = provider.embed('some text here')
      magnitude = Math.sqrt(vec.sum { |v| v**2 })
      expect(magnitude).to be_within(0.001).of(1.0)
    end

    it 'produces similar vectors for related texts' do
      user_model = 'class User < ApplicationRecord; has_many :posts; end'
      post_model = 'class Post < ApplicationRecord; belongs_to :user; end'
      unrelated = 'module CacheWarmer; def warm_redis_connection; redis.ping; end; end'

      vec_user = provider.embed(user_model)
      vec_post = provider.embed(post_model)
      vec_unrelated = provider.embed(unrelated)

      sim_related = cosine_similarity(vec_user, vec_post)
      sim_unrelated = cosine_similarity(vec_user, vec_unrelated)

      expect(sim_related).to be > sim_unrelated
    end

    it 'tracks all calls for inspection' do
      provider.embed('first')
      provider.embed_batch(%w[second third])

      expect(provider.calls.size).to eq(2)
      expect(provider.calls[0]).to eq(['first'])
      expect(provider.calls[1]).to eq(%w[second third])
    end
  end

  describe 'end-to-end: chunk → prepare → embed → store → search' do
    before do
      units.each do |unit|
        chunks = chunker.chunk(unit)
        texts = chunks.map { |c| "#{preparer.prepare(unit)}\n#{c.content}" }
        vectors = provider.embed_batch(texts)

        chunks.each_with_index do |chunk, idx|
          vector_store.store(
            chunk.identifier,
            vectors[idx],
            { type: unit.type.to_s, identifier: unit.identifier,
              chunk_type: chunk.chunk_type.to_s }
          )
        end
      end
    end

    it 'stores vectors for all chunks across all units' do
      expect(vector_store.count).to be > units.size
    end

    it 'finds model chunks when searching with model-related text' do
      query_vec = provider.embed('class User has_many posts belongs_to validations')
      results = vector_store.search(query_vec, limit: 5)

      expect(results).not_to be_empty
      expect(results.first.score).to be > 0.0
    end

    it 'can filter search results by type' do
      query_vec = provider.embed('controller action index show create update')
      results = vector_store.search(query_vec, limit: 10, filters: { type: 'controller' })

      results.each do |result|
        expect(result.metadata[:type]).to eq('controller')
      end
    end

    it 'returns results ordered by similarity score' do
      query_vec = provider.embed('User model with posts and comments')
      results = vector_store.search(query_vec, limit: 10)

      scores = results.map(&:score)
      expect(scores).to eq(scores.sort.reverse)
    end

    it 'ranks model results higher for model-specific queries' do
      query_vec = provider.embed('has_many belongs_to validates presence ApplicationRecord')
      results = vector_store.search(query_vec, limit: 5)

      top_types = results.first(3).map { |r| r.metadata[:type] }
      expect(top_types).to include('model')
    end
  end

  describe 'Indexer orchestrates the full pipeline' do
    let(:output_dir) { Dir.mktmpdir('codebase_index_test') }

    before do
      fixture_hashes.each do |unit_hash|
        type_dir = File.join(output_dir, "#{unit_hash['type']}s")
        FileUtils.mkdir_p(type_dir)
        path = File.join(type_dir, "#{unit_hash['identifier']}.json")
        File.write(path, JSON.generate(unit_hash))
      end
    end

    after do
      FileUtils.rm_rf(output_dir)
    end

    it 'indexes all units and stores vectors' do
      indexer = CodebaseIndex::Embedding::Indexer.new(
        provider: provider,
        text_preparer: preparer,
        vector_store: vector_store,
        output_dir: output_dir,
        batch_size: 4
      )

      stats = indexer.index_all
      expect(stats[:processed]).to eq(fixture_hashes.size)
      expect(stats[:errors]).to eq(0)
      expect(vector_store.count).to eq(fixture_hashes.size)
    end

    it 'skips unchanged units in incremental mode' do
      indexer = CodebaseIndex::Embedding::Indexer.new(
        provider: provider,
        text_preparer: preparer,
        vector_store: vector_store,
        output_dir: output_dir,
        batch_size: 4
      )

      indexer.index_all
      first_count = vector_store.count

      stats = indexer.index_incremental
      expect(stats[:skipped]).to eq(fixture_hashes.size)
      expect(stats[:processed]).to eq(0)
      expect(vector_store.count).to eq(first_count)
    end
  end

  private

  def cosine_similarity(vec_a, vec_b)
    dot = vec_a.zip(vec_b).sum { |a, b| a * b }
    mag_a = Math.sqrt(vec_a.sum { |v| v**2 })
    mag_b = Math.sqrt(vec_b.sum { |v| v**2 })
    return 0.0 if mag_a.zero? || mag_b.zero?

    dot / (mag_a * mag_b)
  end
end
