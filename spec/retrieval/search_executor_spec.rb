# frozen_string_literal: true

require 'spec_helper'
require 'woods/storage/vector_store'
require 'woods/storage/metadata_store'
require 'woods/storage/graph_store'
require 'woods/retrieval/query_classifier'
require 'woods/retrieval/search_executor'
require 'woods/retrieval/ranker'

RSpec.describe Woods::Retrieval::SearchExecutor do
  let(:vector_store) { Woods::Storage::VectorStore::InMemory.new }
  let(:metadata_store) { Woods::Storage::MetadataStore::SQLite.new(database: ':memory:') }
  let(:graph_store) { Woods::Storage::GraphStore::Memory.new }
  let(:classifier) { Woods::Retrieval::QueryClassifier.new }

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
    unit = Woods::ExtractedUnit.new(type: type, identifier: identifier, file_path: file_path)
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

    it 'defaults matched_fields to nil when not provided' do
      candidate = described_class::Candidate.new(
        identifier: 'User', score: 0.95, source: :vector, metadata: {}
      )

      expect(candidate.matched_fields).to be_nil
    end

    it 'stores matched_fields when provided' do
      candidate = described_class::Candidate.new(
        identifier: 'User', score: 0.95, source: :keyword, metadata: {},
        matched_fields: %w[identifier description]
      )

      expect(candidate.matched_fields).to eq(%w[identifier description])
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

    describe 'classifier-derived target_type (#184)' do
      it 'does not push classification.target_type into the vector filter' do
        allow(vector_store).to receive(:search).and_call_original
        classification = classifier.classify('How does the User model handle validation?')
        expect(classification.target_type).to eq(:model)

        executor.execute(query: 'How does the User model handle validation?', classification: classification)

        # target_type stays a soft ranking signal (Ranker's type_match);
        # it must never become a hard vector metadata filter — that
        # excluded every non-matching unit with no fallback.
        expect(vector_store).to have_received(:search).with(anything, hash_including(filters: {}))
      end

      it 'returns candidates of other types even when target_type is set' do
        # Handcrafted classification with target_type :route — the old
        # hard filter turned this into an empty result set (no route
        # units exist), starving mainline queries.
        classification = Woods::Retrieval::QueryClassifier::Classification.new(
          intent: :understand, scope: :focused, target_type: :route,
          framework_context: false, keywords: %w[current user]
        )

        result = executor.execute(query: 'How do we get the current user?', classification: classification)

        expect(result.candidates).not_to be_empty
        # Symbol-keyed on purpose — vector metadata is written symbol-keyed
        # by the Indexer's live embed path and by the Bootstrapper back-fill
        # alike (#150 item 5); hedging with ['type'] here would mask a
        # string-keyed regression on the hydration path.
        types = result.candidates.map { |c| c.metadata[:type] }
        expect(types).not_to include('route')
        expect(types).to include('model')
      end

      it 'surfaces non-route candidates for "How do we get the current user?" end to end' do
        # Pre-#184 this query classified target :route (bare "get") and
        # the vector filter excluded all four seeded units.
        classification = classifier.classify('How do we get the current user?')
        result = executor.execute(query: 'How do we get the current user?', classification: classification)

        expect(result.candidates.map(&:identifier)).to include('User')
      end

      it 'still pushes an explicit type_filter down as a hard vector filter' do
        allow(vector_store).to receive(:search).and_call_original
        classification = classifier.classify('how does auth work?')

        executor.execute(query: 'how does auth work?', classification: classification, type_filter: ['controller'])

        expect(vector_store).to have_received(:search)
          .with(anything, hash_including(filters: { type: %w[controller] }))
      end
    end

    describe 'explicit type_filter: (#108)' do
      it 'pushes type_filter down into vector store filters' do
        classification = classifier.classify('how does auth work?')
        # type_filter restricts vector search to controllers; returns only
        # UsersController from the four seeded units.
        result = executor.execute(
          query: 'how does auth work?',
          classification: classification,
          type_filter: ['controller']
        )
        # Symbol-keyed on purpose — vector metadata is written symbol-keyed
        # by the Indexer's live embed path and by the Bootstrapper back-fill
        # alike (#150 item 5); hedging with ['type'] here would mask a
        # string-keyed regression on the hydration path.
        types = result.candidates.map { |c| c.metadata[:type] }
        expect(types).to all(eq('controller'))
        expect(result.candidates.map(&:identifier)).to eq(%w[UsersController])
      end

      it 'accepts multiple types as an Array' do
        classification = classifier.classify('how does auth work?')
        result = executor.execute(
          query: 'how does auth work?',
          classification: classification,
          type_filter: %w[service controller]
        )
        # Symbol-keyed on purpose — vector metadata is written symbol-keyed
        # by the Indexer's live embed path and by the Bootstrapper back-fill
        # alike (#150 item 5); hedging with ['type'] here would mask a
        # string-keyed regression on the hydration path.
        types = result.candidates.map { |c| c.metadata[:type] }
        expect(types).to all(satisfy { |t| %w[service controller].include?(t) })
        expect(result.candidates.map(&:identifier)).to contain_exactly('UserService', 'UsersController')
      end

      it 'hard-filters on the explicit type_filter even when the classifier derived a target_type' do
        # "how does User model work" sets classification.target_type = :model,
        # but an explicit type_filter: [service] is the caller's intent and
        # is the only thing that filters the vector search.
        classification = classifier.classify('how does the User model work?')
        expect(classification.target_type).to eq(:model)

        result = executor.execute(
          query: 'how does the User model work?',
          classification: classification,
          type_filter: ['service']
        )
        # Symbol-keyed on purpose — vector metadata is written symbol-keyed
        # by the Indexer's live embed path and by the Bootstrapper back-fill
        # alike (#150 item 5); hedging with ['type'] here would mask a
        # string-keyed regression on the hydration path.
        types = result.candidates.map { |c| c.metadata[:type] }
        expect(types).to all(eq('service'))
      end

      it 'treats an empty type_filter as no filter at all' do
        classification = classifier.classify('how does the User model work?')
        result = executor.execute(
          query: 'how does the User model work?',
          classification: classification,
          type_filter: []
        )
        # With type_filter: [], the vector search runs unfiltered — the
        # classifier's target_type :model is a soft ranking signal only
        # (#184), so candidates of every seeded type come back.
        # Symbol-keyed on purpose — vector metadata is written symbol-keyed
        # by the Indexer's live embed path and by the Bootstrapper back-fill
        # alike (#150 item 5); hedging with ['type'] here would mask a
        # string-keyed regression on the hydration path.
        types = result.candidates.map { |c| c.metadata[:type] }
        expect(types).to include('model', 'service', 'controller')
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

    # B-073 / #185 — keyword candidates must carry matched_fields or the
    # Ranker's keyword signal (WEIGHTS[:keyword] = 0.20) scores every
    # candidate 0.0 and is inert. The store's #search doesn't report which
    # fields hit, so the executor approximates from the returned record:
    # every non-bookkeeping field whose value contains the keyword.
    describe 'matched_fields population (B-073)' do
      it 'names the record fields whose values matched the keyword' do
        classification = classifier.classify('Where is the User defined?')
        result = executor.execute(query: 'Where is the User defined?', classification: classification)

        user = result.candidates.find { |c| c.identifier == 'User' }
        expect(user).not_to be_nil
        # Seeded record: type=model, identifier=User, file_path=app/models/user.rb,
        # description="The User model" — "user" matches all but type.
        expect(user.matched_fields).to contain_exactly('identifier', 'file_path', 'description')
      end

      it 'never counts the store-injected id field as a match' do
        classification = classifier.classify('Where is the User defined?')
        result = executor.execute(query: 'Where is the User defined?', classification: classification)

        result.candidates.each do |candidate|
          expect(candidate.matched_fields).not_to include('id') if candidate.matched_fields
        end
      end

      it 'leaves matched_fields nil on vector candidates' do
        classification = classifier.classify('How does authentication work?')
        result = executor.execute(query: 'How does authentication work?', classification: classification)

        expect(result.candidates).not_to be_empty
        expect(result.candidates.map(&:matched_fields)).to all(be_nil)
      end
    end

    # The metadata store's #search has no ORDER BY, so a score derived from
    # result-row position tracked arbitrary row order instead of relevance.
    # Insert the weaker match FIRST so it would land at row index 0 (the
    # position-based score's highest slot) and prove the fix ranks on match
    # quality regardless.
    describe 'scoring by match quality, not row position' do
      let(:keyword_classification) do
        Woods::Retrieval::QueryClassifier::Classification.new(
          intent: :locate, scope: :focused, target_type: nil,
          framework_context: false, keywords: ['zzzneedle']
        )
      end

      before do
        metadata_store.store('AloneMatch', {
                               type: 'model', identifier: 'zzzneedleAlone',
                               file_path: 'app/models/other.rb', description: 'unrelated'
                             })
        metadata_store.store('FullMatch', {
                               type: 'model', identifier: 'zzzneedleFull',
                               file_path: 'app/models/zzzneedle_full.rb',
                               description: 'zzzneedle everywhere'
                             })
      end

      it 'ranks the candidate with more matched fields above one with fewer, despite insertion order' do
        result = executor.execute(query: 'zzzneedle', classification: keyword_classification)

        alone = result.candidates.find { |c| c.identifier == 'AloneMatch' }
        full = result.candidates.find { |c| c.identifier == 'FullMatch' }

        expect(alone.matched_fields.size).to be < full.matched_fields.size
        expect(full.score).to be > alone.score
      end

      it 'keeps every keyword score within (0.0, 1.0]' do
        result = executor.execute(query: 'zzzneedle', classification: keyword_classification)

        expect(result.candidates.map(&:score)).to all(be_between(0.0, 1.0).inclusive)
        expect(result.candidates.map(&:score)).to all(be > 0.0)
      end
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

    # P1 fix: execute_hybrid used to run deduplicate(all).first(limit)
    # BEFORE the Ranker ever saw the candidates, keeping only the
    # best-scored source per identifier — so a unit found by both vector
    # AND keyword search only ever reached the Ranker as one source, and
    # RRF's cross-source sum (compute_rrf_scores) never accumulated.
    # "Hybrid" was concatenation, not fusion. Deduplication now happens
    # once — inside Ranker's RRF merge, which is where cross-source
    # consensus is computed — not twice.
    describe 'RRF consensus (P1)' do
      # Forces classification.keywords so keyword search hits 'User'
      # directly, and the fixed embedding stub always ranks 'User' first
      # on the vector side — a real overlap, unlike the natural classifier
      # output for a broad query, which can miss it entirely depending on
      # keyword extraction.
      let(:overlapping_classification) do
        Woods::Retrieval::QueryClassifier::Classification.new(
          intent: :understand, scope: :comprehensive, target_type: nil,
          framework_context: false, keywords: ['user']
        )
      end

      it 'does not pre-deduplicate a candidate found by multiple sources' do
        result = executor.execute(query: 'user', classification: overlapping_classification, strategy: :hybrid)

        user_entries = result.candidates.select { |c| c.identifier == 'User' }
        expect(user_entries.map(&:source)).to include(:vector, :keyword)
      end

      it 'lets a multi-source candidate outrank an equally-scored single-source one after Ranker fusion' do
        ranker = Woods::Retrieval::Ranker.new(metadata_store: metadata_store, graph_store: graph_store)
        result = executor.execute(query: 'user', classification: overlapping_classification, strategy: :hybrid)

        ranked = ranker.rank(result.candidates, classification: overlapping_classification)

        # UsersController is keyword-only; User is both vector- and
        # keyword-found. RRF consensus must place User first.
        expect(ranked.first.identifier).to eq('User')
        expect(ranked.map(&:identifier).count('User')).to eq(1)
      end

      it 'keeps a weaker source duplicate of a kept unit through the limit cut' do
        result = executor.execute(
          query: 'user', classification: overlapping_classification, strategy: :hybrid, limit: 1
        )

        user_entries = result.candidates.select { |c| c.identifier == 'User' }
        expect(user_entries.map(&:source)).to include(:vector, :keyword)
        unique_units = result.candidates.map { |c| c.identifier.sub(/#chunk_\d+\z/, '') }.uniq
        expect(unique_units.size).to eq(1)
      end

      it 'leaves single-strategy (non-hybrid) paths deduplication-free as before' do
        classification = classifier.classify('Where is the User defined?')
        result = executor.execute(query: 'Where is the User defined?', classification: classification)

        identifiers = result.candidates.map(&:identifier)
        expect(identifiers).to eq(identifiers.uniq)
      end
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
    let(:empty_vector) { Woods::Storage::VectorStore::InMemory.new }
    let(:empty_metadata) { Woods::Storage::MetadataStore::SQLite.new(database: ':memory:') }
    let(:empty_graph) { Woods::Storage::GraphStore::Memory.new }

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
