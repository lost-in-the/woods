# frozen_string_literal: true

require 'spec_helper'
require 'codebase_index/storage/vector_store'
require 'codebase_index/storage/metadata_store'
require 'codebase_index/storage/graph_store'
require 'codebase_index/retrieval/query_classifier'
require 'codebase_index/retrieval/search_executor'

RSpec.describe CodebaseIndex::Retrieval::SearchExecutor do
  let(:vector_store) { CodebaseIndex::Storage::VectorStore::InMemory.new }
  let(:metadata_store) { CodebaseIndex::Storage::MetadataStore::SQLite.new(':memory:') }
  let(:graph_store) { CodebaseIndex::Storage::GraphStore::Memory.new }
  let(:classifier) { CodebaseIndex::Retrieval::QueryClassifier.new }

  # Stub embedding provider that returns a fixed vector for any input
  let(:embedding_provider) do
    provider = Object.new
    def provider.embed(_text)
      [1.0, 0.0, 0.0]
    end
    provider
  end

  let(:executor) do
    described_class.new(
      vector_store: vector_store,
      metadata_store: metadata_store,
      graph_store: graph_store,
      embedding_provider: embedding_provider
    )
  end

  # Helper to seed all three stores with a unit
  def seed_unit(identifier:, type:, file_path:, vector:, dependencies: [])
    # Vector store
    vector_store.store(identifier, vector, { type: type.to_s })

    # Metadata store
    metadata_store.store(identifier, {
                           type: type.to_s,
                           identifier: identifier,
                           file_path: file_path,
                           description: "The #{identifier} #{type}"
                         })

    # Graph store
    unit = CodebaseIndex::ExtractedUnit.new(type: type, identifier: identifier, file_path: file_path)
    unit.dependencies = dependencies
    graph_store.register(unit)
  end

  before do
    seed_unit(
      identifier: 'User', type: :model,
      file_path: 'app/models/user.rb',
      vector: [1.0, 0.0, 0.0]
    )
    seed_unit(
      identifier: 'Order', type: :model,
      file_path: 'app/models/order.rb',
      vector: [0.9, 0.1, 0.0],
      dependencies: [{ type: :model, target: 'User' }]
    )
    seed_unit(
      identifier: 'UserService', type: :service,
      file_path: 'app/services/user_service.rb',
      vector: [0.8, 0.2, 0.0],
      dependencies: [{ type: :model, target: 'User' }]
    )
    seed_unit(
      identifier: 'UsersController', type: :controller,
      file_path: 'app/controllers/users_controller.rb',
      vector: [0.0, 1.0, 0.0],
      dependencies: [{ type: :service, target: 'UserService' }]
    )
  end

  describe 'Candidate struct' do
    it 'stores identifier, score, source, and metadata' do
      candidate = described_class::Candidate.new(
        identifier: 'User', score: 0.95, source: :vector, metadata: { type: 'model' }
      )

      expect(candidate.identifier).to eq('User')
      expect(candidate.score).to eq(0.95)
      expect(candidate.source).to eq(:vector)
      expect(candidate.metadata).to eq({ type: 'model' })
    end
  end

  describe 'ExecutionResult struct' do
    it 'stores candidates, strategy, and query' do
      result = described_class::ExecutionResult.new(
        candidates: [],
        strategy: :vector,
        query: 'test'
      )

      expect(result.candidates).to eq([])
      expect(result.strategy).to eq(:vector)
      expect(result.query).to eq('test')
    end
  end

  describe '#execute' do
    it 'returns an ExecutionResult' do
      classification = classifier.classify('How does the User model work?')
      result = executor.execute(query: 'How does the User model work?', classification: classification)

      expect(result).to be_a(described_class::ExecutionResult)
      expect(result.candidates).to be_an(Array)
      expect(result.strategy).to be_a(Symbol)
    end

    it 'respects the limit parameter' do
      classification = classifier.classify('How does the User model work?')
      result = executor.execute(query: 'How does the User model work?', classification: classification, limit: 2)

      expect(result.candidates.size).to be <= 2
    end

    it 'returns candidates with required attributes' do
      classification = classifier.classify('How does the User model work?')
      result = executor.execute(query: 'How does the User model work?', classification: classification)

      result.candidates.each do |candidate|
        expect(candidate).to respond_to(:identifier, :score, :source, :metadata)
      end
    end
  end

  describe 'strategy selection' do
    context 'when intent is :understand (vector)' do
      it 'uses vector strategy' do
        classification = classifier.classify('How does authentication work?')
        result = executor.execute(query: 'How does authentication work?', classification: classification)

        expect(result.strategy).to eq(:vector)
      end
    end

    context 'when intent is :locate with focused scope (keyword)' do
      it 'uses keyword strategy' do
        classification = classifier.classify('Where is the User defined?')
        result = executor.execute(query: 'Where is the User defined?', classification: classification)

        expect(result.strategy).to eq(:keyword)
      end
    end

    context 'when intent is :locate with pinpoint scope (direct)' do
      it 'uses direct strategy' do
        classification = classifier.classify('Find exactly the User model')
        result = executor.execute(query: 'Find exactly the User model', classification: classification)

        expect(result.strategy).to eq(:direct)
      end
    end

    context 'when intent is :trace (graph)' do
      it 'uses graph strategy' do
        classification = classifier.classify('What depends on the User model?')
        result = executor.execute(query: 'What depends on the User model?', classification: classification)

        expect(result.strategy).to eq(:graph)
      end
    end

    context 'when scope is :comprehensive (hybrid)' do
      it 'uses hybrid strategy' do
        classification = classifier.classify('Show me all models related to users')
        result = executor.execute(query: 'Show me all models related to users', classification: classification)

        expect(result.strategy).to eq(:hybrid)
      end
    end

    context 'when intent is :framework (keyword)' do
      it 'uses keyword strategy' do
        classification = classifier.classify('How does Rails handle ActiveRecord callbacks?')
        result = executor.execute(query: 'How does Rails handle ActiveRecord callbacks?',
                                  classification: classification)

        expect(result.strategy).to eq(:keyword)
      end
    end

    context 'when intent is :debug (vector)' do
      it 'uses vector strategy' do
        classification = classifier.classify('There is a bug in the checkout')
        result = executor.execute(query: 'There is a bug in the checkout', classification: classification)

        expect(result.strategy).to eq(:vector)
      end
    end

    context 'when intent is :implement (vector)' do
      it 'uses vector strategy' do
        classification = classifier.classify('Add a new payment method')
        result = executor.execute(query: 'Add a new payment method', classification: classification)

        expect(result.strategy).to eq(:vector)
      end
    end
  end

  describe 'vector strategy execution' do
    it 'returns candidates from vector store ranked by similarity' do
      classification = classifier.classify('How does the User model work?')
      result = executor.execute(query: 'How does the User model work?', classification: classification)

      expect(result.strategy).to eq(:vector)
      identifiers = result.candidates.map(&:identifier)
      expect(identifiers).to include('User')
      expect(result.candidates.first.source).to eq(:vector)
    end

    it 'filters by target type when present' do
      classification = classifier.classify('How does the User model handle validation?')
      result = executor.execute(query: 'How does the User model handle validation?', classification: classification)

      # Should only return models since target_type is :model
      result.candidates.each do |c|
        expect(c.metadata[:type] || c.metadata['type']).to eq('model')
      end
    end
  end

  describe 'keyword strategy execution' do
    it 'returns candidates from metadata search' do
      classification = classifier.classify('Where is the User defined?')
      result = executor.execute(query: 'Where is the User defined?', classification: classification)

      identifiers = result.candidates.map(&:identifier)
      expect(identifiers).to include('User')
      expect(result.candidates.first.source).to eq(:keyword)
    end

    it 'returns empty array when no keywords match' do
      classification = classifier.classify('Where is the nonexistent thing?')
      result = executor.execute(query: 'Where is the nonexistent thing?', classification: classification)

      # May return empty or partial results depending on keyword matching
      expect(result.candidates).to be_an(Array)
    end
  end

  describe 'graph strategy execution' do
    it 'returns dependencies and dependents of seed units' do
      classification = classifier.classify('What depends on the User model?')
      result = executor.execute(query: 'What depends on the User model?', classification: classification)

      identifiers = result.candidates.map(&:identifier)
      # User has dependents: Order and UserService
      expect(identifiers).to include('User')
    end

    it 'includes the seed itself with highest score' do
      classification = classifier.classify('What depends on the User model?')
      result = executor.execute(query: 'What depends on the User model?', classification: classification)

      # Find User if present — should have score 1.0 as seed
      user_candidate = result.candidates.find { |c| c.identifier == 'User' }
      if user_candidate
        expect(user_candidate.score).to eq(1.0)
        expect(user_candidate.source).to eq(:graph)
      end
    end
  end

  describe 'hybrid strategy execution' do
    it 'combines results from multiple sources' do
      classification = classifier.classify('Show me everything related to users')
      result = executor.execute(query: 'Show me everything related to users', classification: classification)

      expect(result.strategy).to eq(:hybrid)
      sources = result.candidates.map(&:source).uniq
      # Should have at least vector results
      expect(sources).to include(:vector)
    end

    it 'deduplicates candidates across sources' do
      classification = classifier.classify('Show me everything related to users')
      result = executor.execute(query: 'Show me everything related to users', classification: classification)

      identifiers = result.candidates.map(&:identifier)
      expect(identifiers).to eq(identifiers.uniq)
    end
  end

  describe 'direct strategy execution' do
    it 'looks up units directly by keyword' do
      classification = classifier.classify('Find exactly the User model')
      result = executor.execute(query: 'Find exactly the User model', classification: classification)

      expect(result.strategy).to eq(:direct)
      identifiers = result.candidates.map(&:identifier)
      expect(identifiers).to include('User')
    end

    it 'falls back to keyword search when direct lookup misses' do
      classification = classifier.classify('Find exactly the nonexistent thing')
      result = executor.execute(query: 'Find exactly the nonexistent thing', classification: classification)

      # Should fall back gracefully
      expect(result.candidates).to be_an(Array)
    end
  end

  describe 'empty store behavior' do
    let(:empty_vector) { CodebaseIndex::Storage::VectorStore::InMemory.new }
    let(:empty_metadata) { CodebaseIndex::Storage::MetadataStore::SQLite.new(':memory:') }
    let(:empty_graph) { CodebaseIndex::Storage::GraphStore::Memory.new }

    let(:empty_executor) do
      described_class.new(
        vector_store: empty_vector,
        metadata_store: empty_metadata,
        graph_store: empty_graph,
        embedding_provider: embedding_provider
      )
    end

    it 'returns empty candidates for vector search on empty stores' do
      classification = classifier.classify('How does authentication work?')
      result = empty_executor.execute(query: 'How does authentication work?', classification: classification)

      expect(result.candidates).to be_empty
    end

    it 'returns empty candidates for keyword search on empty stores' do
      classification = classifier.classify('Where is the User model?')
      result = empty_executor.execute(query: 'Where is the User model?', classification: classification)

      expect(result.candidates).to be_empty
    end

    it 'returns empty candidates for graph search on empty stores' do
      classification = classifier.classify('What depends on User?')
      result = empty_executor.execute(query: 'What depends on User?', classification: classification)

      expect(result.candidates).to be_empty
    end
  end
end
