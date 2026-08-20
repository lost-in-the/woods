# frozen_string_literal: true

require 'spec_helper'
require 'woods'
require 'woods/retriever'

RSpec.describe Woods::Retriever do
  let(:vector_store) { double('VectorStore') }
  let(:metadata_store) { double('MetadataStore') }
  let(:graph_store) { double('GraphStore') }
  let(:embedding_provider) { double('EmbeddingProvider') }
  let(:formatter) { nil }

  let(:classifier_double) { instance_double(Woods::Retrieval::QueryClassifier) }
  let(:executor_double) { instance_double(Woods::Retrieval::SearchExecutor) }
  let(:ranker_double) { instance_double(Woods::Retrieval::Ranker) }
  let(:assembler_double) { instance_double(Woods::Retrieval::ContextAssembler) }

  let(:retriever) do
    described_class.new(
      vector_store: vector_store,
      metadata_store: metadata_store,
      graph_store: graph_store,
      embedding_provider: embedding_provider,
      formatter: formatter
    )
  end

  let(:classification) do
    Woods::Retrieval::QueryClassifier::Classification.new(
      intent: :understand,
      scope: :focused,
      target_type: :model,
      framework_context: false,
      keywords: %w[user model]
    )
  end

  let(:candidates) do
    [
      Woods::Retrieval::SearchExecutor::Candidate.new(
        identifier: 'User', score: 0.9, source: :vector, metadata: { type: 'model' }
      )
    ]
  end

  let(:execution_result) do
    Woods::Retrieval::SearchExecutor::ExecutionResult.new(
      candidates: candidates,
      strategy: :vector,
      query: 'How does the User model work?'
    )
  end

  let(:ranked_candidates) { candidates }

  let(:assembled_context) do
    Woods::Retrieval::AssembledContext.new(
      context: '## User (model)\nclass User < ApplicationRecord; end',
      tokens_used: 120,
      budget: 8000,
      sources: [{ identifier: 'User', type: :model, score: 0.9, file_path: 'app/models/user.rb' }],
      sections: %i[structural primary]
    )
  end

  before do
    allow(Woods::Retrieval::QueryClassifier).to receive(:new).and_return(classifier_double)
    allow(Woods::Retrieval::SearchExecutor).to receive(:new).and_return(executor_double)
    allow(Woods::Retrieval::Ranker).to receive(:new).and_return(ranker_double)
    allow(Woods::Retrieval::ContextAssembler).to receive(:new).and_return(assembler_double)

    allow(classifier_double).to receive(:classify).and_return(classification)
    allow(executor_double).to receive(:execute).and_return(execution_result)
    allow(ranker_double).to receive(:rank).and_return(ranked_candidates)
    allow(assembler_double).to receive(:assemble).and_return(assembled_context)

    # build_structural_context calls metadata_store.count; default to 0 (nil result)
    allow(metadata_store).to receive(:count).and_return(0)
    # build_type_rank_context calls find_by_type for each requested type.
    # Empty Array is the right default — tests that care about the total_of_type
    # value override per-example.
    allow(metadata_store).to receive(:find_by_type).and_return([])
  end

  # ── #retrieve ──────────────────────────────────────────────────────

  describe '#retrieve' do
    it 'returns a RetrievalResult' do
      result = retriever.retrieve('How does the User model work?')

      expect(result).to be_a(Woods::Retriever::RetrievalResult)
    end

    it 'includes context from assembler' do
      result = retriever.retrieve('How does the User model work?')

      expect(result.context).to eq(assembled_context.context)
    end

    it 'includes classification' do
      result = retriever.retrieve('How does the User model work?')

      expect(result.classification).to eq(classification)
    end

    it 'includes strategy from execution' do
      result = retriever.retrieve('How does the User model work?')

      expect(result.strategy).to eq(:vector)
    end

    it 'includes sources from assembler' do
      result = retriever.retrieve('How does the User model work?')

      expect(result.sources).to eq(assembled_context.sources)
    end

    it 'includes tokens_used from assembler' do
      result = retriever.retrieve('How does the User model work?')

      expect(result.tokens_used).to eq(120)
    end

    it 'includes budget' do
      result = retriever.retrieve('How does the User model work?')

      expect(result.budget).to eq(8000)
    end

    it 'accepts an optional budget parameter' do
      result = retriever.retrieve('How does the User model work?', budget: 4000)

      expect(result.budget).to eq(4000)
    end

    it 'uses default budget of 8000 when none provided' do
      result = retriever.retrieve('How does the User model work?')

      expect(result.budget).to eq(8000)
    end

    it 'passes budget to context assembler' do
      expect(assembler_double)
        .to receive(:assemble)
        .with(hash_including(budget: 4000, structural_context: anything))
        .and_return(assembled_context)

      retriever.retrieve('How does the User model work?', budget: 4000)
    end

    it 'passes default budget of 8000 to context assembler when no budget given' do
      expect(assembler_double)
        .to receive(:assemble)
        .with(hash_including(budget: 8000))
        .and_return(assembled_context)

      retriever.retrieve('How does the User model work?')
    end

    it 'applies formatter when provided' do
      custom_formatter = ->(ctx) { "FORMATTED: #{ctx}" }
      formatted_retriever = described_class.new(
        vector_store: vector_store,
        metadata_store: metadata_store,
        graph_store: graph_store,
        embedding_provider: embedding_provider,
        formatter: custom_formatter
      )

      result = formatted_retriever.retrieve('How does the User model work?')

      expect(result.context).to eq("FORMATTED: #{assembled_context.context}")
    end

    it 'does not modify context when formatter is nil' do
      result = retriever.retrieve('How does the User model work?')

      expect(result.context).to eq(assembled_context.context)
    end
  end

  # ── Query validation boundary (P1) ────────────────────────────────
  #
  # Pre-fix, #retrieve performed no validation: a blank query surfaced as
  # a raw provider ArgumentError only on the vector path (keyword/graph
  # paths tolerated it silently), and an oversized query went to the
  # embedding/metadata providers verbatim to fail as an opaque 400. This
  # boundary runs first, before classify/execute/rank/assemble, so every
  # strategy shares one typed, actionable failure mode.
  describe 'query validation' do
    it 'rejects a nil query' do
      expect { retriever.retrieve(nil) }.to raise_error(Woods::InvalidQueryError, /string/i)
    end

    it 'rejects a non-String query' do
      expect { retriever.retrieve(42) }.to raise_error(Woods::InvalidQueryError, /string/i)
    end

    it 'rejects a blank query' do
      expect { retriever.retrieve('') }.to raise_error(Woods::InvalidQueryError, /blank/i)
    end

    it 'rejects a whitespace-only query' do
      expect { retriever.retrieve("   \n\t  ") }.to raise_error(Woods::InvalidQueryError, /blank/i)
    end

    it 'rejects a query over the byte cap' do
      oversized = 'a' * (Woods::Retriever::MAX_QUERY_BYTES + 1)
      expect { retriever.retrieve(oversized) }.to raise_error(Woods::InvalidQueryError, /exceeds/i)
    end

    it 'does not raise for a normal query' do
      expect { retriever.retrieve('How does the User model work?') }.not_to raise_error
    end

    it 'raises a stable error class that is a Woods::Error' do
      expect(Woods::InvalidQueryError.ancestors).to include(Woods::Error)
      expect { retriever.retrieve('') }.to raise_error(an_instance_of(Woods::InvalidQueryError))
    end

    it 'never reaches the classifier when the query fails validation' do
      expect(classifier_double).not_to receive(:classify)
      expect { retriever.retrieve('') }.to raise_error(Woods::InvalidQueryError)
    end
  end

  # ── Type filtering ──────────────────────────────────────────────

  describe 'type filtering' do
    # Regression — test_mapping units make up ~33% of a typical index and
    # lexically dominate semantic rank on production queries. The Retriever
    # now default-excludes them unless the caller explicitly opts back in
    # via types:. Callers can also add more exclusions via exclude_types:.
    let(:mixed_candidates) do
      [
        Woods::Retrieval::SearchExecutor::Candidate.new(
          identifier: 'StripeWebhooksController', score: 0.9, source: :vector,
          metadata: { type: 'controller' }
        ),
        Woods::Retrieval::SearchExecutor::Candidate.new(
          identifier: 'StripeWebhooksControllerSpec', score: 0.85, source: :vector,
          metadata: { type: 'test_mapping' }
        ),
        Woods::Retrieval::SearchExecutor::Candidate.new(
          identifier: 'Stripe::Webhook', score: 0.8, source: :vector,
          metadata: { type: 'rails_source' }
        )
      ]
    end

    before do
      allow(ranker_double).to receive(:rank).and_return(mixed_candidates)
    end

    it 'excludes test_mapping candidates by default' do
      expect(assembler_double).to receive(:assemble) do |kwargs|
        types = kwargs[:candidates].map { |c| c.metadata[:type] }
        expect(types).not_to include('test_mapping')
        assembled_context
      end

      retriever.retrieve('stripe webhook')
    end

    it 'opts test_mappings back in when types: explicitly includes them' do
      expect(assembler_double).to receive(:assemble) do |kwargs|
        types = kwargs[:candidates].map { |c| c.metadata[:type] }
        expect(types).to include('test_mapping')
        expect(types).not_to include('controller', 'rails_source')
        assembled_context
      end

      retriever.retrieve('stripe webhook', types: %w[test_mapping])
    end

    it 'accepts exclude_types: for additional exclusions on top of the default' do
      expect(assembler_double).to receive(:assemble) do |kwargs|
        types = kwargs[:candidates].map { |c| c.metadata[:type] }
        expect(types).to eq(%w[controller])
        assembled_context
      end

      retriever.retrieve('stripe webhook', exclude_types: %w[rails_source])
    end

    it 'falls back to metadata_store lookup when candidate metadata has no :type' do
      # Graph-expansion candidates come in with metadata: {} — the filter
      # must still resolve their type via the metadata store.
      bare_candidate = Woods::Retrieval::SearchExecutor::Candidate.new(
        identifier: 'Orphan', score: 0.5, source: :graph_expansion, metadata: {}
      )
      allow(ranker_double).to receive(:rank).and_return([bare_candidate])
      allow(metadata_store).to receive(:find).with('Orphan').and_return('type' => 'test_mapping')

      expect(assembler_double).to receive(:assemble) do |kwargs|
        expect(kwargs[:candidates]).to be_empty
        assembled_context
      end

      retriever.retrieve('orphan')
    end

    it 'strips #chunk_N suffix before the metadata_store lookup' do
      # Vector hits for chunked units arrive with identifiers like
      # +spec/requests/stripe_webhooks_spec.rb#chunk_0+ but the metadata
      # store keys them under the base identifier only. Without stripping,
      # the fallback lookup misses, candidate_type falls through to '',
      # and the default exclude_types filter lets test_mappings through.
      chunked_candidate = Woods::Retrieval::SearchExecutor::Candidate.new(
        identifier: 'spec/requests/stripe_webhooks_spec.rb#chunk_0',
        score: 0.95, source: :vector, metadata: {}
      )
      allow(ranker_double).to receive(:rank).and_return([chunked_candidate])
      allow(metadata_store).to receive(:find)
        .with('spec/requests/stripe_webhooks_spec.rb')
        .and_return('type' => 'test_mapping')

      expect(assembler_double).to receive(:assemble) do |kwargs|
        expect(kwargs[:candidates]).to be_empty
        assembled_context
      end

      retriever.retrieve('stripe webhook signature verification')
    end
  end

  # ── #108 rank-within-type + type_rank_context ──────────────────

  describe 'types: rank context (#108)' do
    let(:ranked_candidates) do
      [
        Woods::Retrieval::SearchExecutor::Candidate.new(
          identifier: 'AuthService', score: 0.92, source: :vector,
          metadata: { type: 'service' }
        ),
        Woods::Retrieval::SearchExecutor::Candidate.new(
          identifier: 'UsersController', score: 0.85, source: :vector,
          metadata: { type: 'controller' }
        ),
        Woods::Retrieval::SearchExecutor::Candidate.new(
          identifier: 'SessionsController', score: 0.74, source: :vector,
          metadata: { type: 'controller' }
        )
      ]
    end

    before do
      allow(ranker_double).to receive(:rank).and_return(ranked_candidates)
      allow(metadata_store).to receive(:find_by_type).with('controller').and_return(Array.new(42))
      allow(metadata_store).to receive(:find_by_type).with('service').and_return(Array.new(17))
      allow(metadata_store).to receive(:find_by_type).with('mailer').and_return(Array.new(3))
    end

    it 'returns nil type_rank_context when types: is not set' do
      result = retriever.retrieve('how does auth work?')
      expect(result.type_rank_context).to be_nil
    end

    it 'populates top_of_type_global_rank from the unfiltered ranked list' do
      result = retriever.retrieve('how does auth work?', types: %w[controller])
      expect(result.type_rank_context['controller']).to eq(
        source: :in_top_k,
        top_of_type_global_rank: 2, # UsersController is rank 2
        global_k: 3,
        total_of_type: 42
      )
    end

    it 'emits per-type entries for multi-type requests' do
      result = retriever.retrieve('how does auth work?', types: %w[controller service])
      expect(result.type_rank_context.keys).to contain_exactly('controller', 'service')
      expect(result.type_rank_context['service'][:top_of_type_global_rank]).to eq(1)
      expect(result.type_rank_context['service'][:source]).to eq(:in_top_k)
      expect(result.type_rank_context['controller'][:top_of_type_global_rank]).to eq(2)
      expect(result.type_rank_context['controller'][:source]).to eq(:in_top_k)
    end

    it 'marks :source as :within_type_fallback when the type is missing from top-K but exists in the index' do
      # mailer isn't in ranked_candidates; fallback runs with mailer
      # candidate and the per-type :source reflects that path.
      mailer_candidate = Woods::Retrieval::SearchExecutor::Candidate.new(
        identifier: 'UserMailer', score: 0.4, source: :vector,
        metadata: { type: 'mailer' }
      )
      fallback_result = instance_double(
        Woods::Retrieval::SearchExecutor::ExecutionResult,
        candidates: [mailer_candidate], strategy: :vector, query: 'how does auth work?'
      )
      allow(executor_double).to receive(:execute).and_return(fallback_result)
      allow(ranker_double).to receive(:rank).and_return(ranked_candidates, [mailer_candidate])

      result = retriever.retrieve('how does auth work?', types: %w[mailer])
      expect(result.type_rank_context['mailer']).to eq(
        source: :within_type_fallback,
        top_of_type_global_rank: nil,
        global_k: 3,
        total_of_type: 3
      )
    end

    it 'marks :source as :outside_top_k when the type exists in the index but fallback did not run' do
      # Multi-type query where one type is in top-K (controller) and
      # another isn't (mailer). filtered is non-empty from controllers,
      # so fallback skips. mailer's :source is :outside_top_k.
      result = retriever.retrieve('how does auth work?', types: %w[controller mailer])
      expect(result.type_rank_context['controller'][:source]).to eq(:in_top_k)
      expect(result.type_rank_context['mailer']).to include(
        source: :outside_top_k,
        top_of_type_global_rank: nil,
        total_of_type: 3
      )
    end

    it 'falls back to rank-within-type when the global top-K has no candidate of the requested type' do
      # mailer has zero candidates in the global ranked list. The executor
      # should be called a second time with type_filter so we return a
      # mailer rather than empty.
      mailer_candidate = Woods::Retrieval::SearchExecutor::Candidate.new(
        identifier: 'UserMailer', score: 0.4, source: :vector,
        metadata: { type: 'mailer' }
      )
      fallback_result = instance_double(
        Woods::Retrieval::SearchExecutor::ExecutionResult,
        candidates: [mailer_candidate], strategy: :vector, query: 'how does auth work?'
      )
      expect(executor_double).to receive(:execute)
        .with(hash_including(type_filter: %w[mailer]))
        .and_return(fallback_result)
      allow(ranker_double).to receive(:rank).and_return(ranked_candidates, [mailer_candidate])

      expect(assembler_double).to receive(:assemble) do |kwargs|
        expect(kwargs[:candidates].map(&:identifier)).to eq(%w[UserMailer])
        assembled_context
      end

      result = retriever.retrieve('how does auth work?', types: %w[mailer])
      # type_rank_context reports nil top-of-type — this match wasn't in the
      # original global top-K; fallback surfaced it.
      expect(result.type_rank_context['mailer'][:top_of_type_global_rank]).to be_nil
    end

    it 'does not invoke the fallback query when the global top-K already has the type' do
      expect(executor_double).not_to receive(:execute).with(hash_including(type_filter: anything))
      retriever.retrieve('how does auth work?', types: %w[controller])
    end

    it 'appends a type rank context table to the context string when types: is set' do
      result = retriever.retrieve('how does auth work?', types: %w[controller])
      expect(result.context).to include('### Type rank context')
      expect(result.context).to include('| controller | in_top_k | 2 | 3 | 42 |')
    end

    it 'forces strategy: :vector in the fallback so keyword/graph/direct classifications still surface results' do
      # Simulate a query the classifier sends to :keyword strategy.
      # Without a strategy override, the fallback would re-run :keyword
      # (which ignores type_filter) and come back empty. With the
      # override, :vector runs and returns a mailer.
      keyword_classification = instance_double(
        Woods::Retrieval::QueryClassifier::Classification,
        intent: :locate, scope: :broad, target_type: nil, keywords: %w[mailer]
      )
      allow(classifier_double).to receive(:classify).and_return(keyword_classification)

      mailer_candidate = Woods::Retrieval::SearchExecutor::Candidate.new(
        identifier: 'UserMailer', score: 0.4, source: :vector,
        metadata: { type: 'mailer' }
      )
      global_result = instance_double(
        Woods::Retrieval::SearchExecutor::ExecutionResult,
        candidates: [], strategy: :keyword, query: 'find mailer'
      )
      vector_fallback = instance_double(
        Woods::Retrieval::SearchExecutor::ExecutionResult,
        candidates: [mailer_candidate], strategy: :vector, query: 'find mailer'
      )
      allow(executor_double).to receive(:execute) do |**kwargs|
        kwargs[:strategy] == :vector ? vector_fallback : global_result
      end
      allow(ranker_double).to receive(:rank).and_return([], [mailer_candidate])

      retriever.retrieve('find mailer', types: %w[mailer])
      expect(executor_double).to have_received(:execute).with(
        hash_including(strategy: :vector, type_filter: %w[mailer])
      )
    end

    it 'skips the fallback entirely when every requested type has 0 units in the index' do
      allow(metadata_store).to receive(:find_by_type).with('nonexistent').and_return([])
      empty_result = instance_double(
        Woods::Retrieval::SearchExecutor::ExecutionResult,
        candidates: [], strategy: :vector, query: 'x'
      )
      # Only the initial (non-fallback) execute call should fire — a
      # second call would mean we wasted a vector search on a type we
      # already know doesn't exist.
      expect(executor_double).to receive(:execute).once.and_return(empty_result)
      allow(ranker_double).to receive(:rank).and_return([])

      result = retriever.retrieve('x', types: %w[nonexistent])
      expect(result.type_rank_context['nonexistent'][:source]).to eq(:absent)
      expect(result.type_rank_context['nonexistent'][:total_of_type]).to eq(0)
    end

    it 'records total_of_type: 0 and :source :absent when the index has no units of the requested type' do
      allow(metadata_store).to receive(:find_by_type).with('policy').and_return([])
      # with zero of that type in the index, fallback runs but returns nothing
      empty_fallback = instance_double(
        Woods::Retrieval::SearchExecutor::ExecutionResult,
        candidates: [], strategy: :vector, query: 'how does auth work?'
      )
      allow(executor_double).to receive(:execute).and_return(empty_fallback)
      allow(ranker_double).to receive(:rank).and_return(ranked_candidates, [])

      result = retriever.retrieve('how does auth work?', types: %w[policy])
      expect(result.type_rank_context['policy'][:total_of_type]).to eq(0)
    end
  end

  # ── Pipeline integration ─────────────────────────────────────────

  describe 'pipeline flow' do
    it 'calls classify, execute, rank, assemble in sequence' do
      expect(classifier_double).to receive(:classify).with('test query').and_return(classification).ordered
      expect(executor_double).to receive(:execute)
        .with(query: 'test query', classification: classification)
        .and_return(execution_result).ordered
      expect(ranker_double).to receive(:rank)
        .with(candidates, classification: classification)
        .and_return(ranked_candidates).ordered
      expect(assembler_double).to receive(:assemble)
        .with(candidates: ranked_candidates, classification: classification, structural_context: anything,
              budget: anything)
        .and_return(assembled_context).ordered

      # Need to allow metadata_store calls for structural context
      allow(metadata_store).to receive(:count).and_return(0)

      retriever.retrieve('test query')
    end
  end

  # ── RetrievalResult struct ───────────────────────────────────────

  describe 'RetrievalResult' do
    it 'has all expected fields' do
      result = Woods::Retriever::RetrievalResult.new(
        context: 'some context',
        sources: [],
        classification: classification,
        strategy: :vector,
        tokens_used: 100,
        budget: 8000
      )

      expect(result).to respond_to(:context, :sources, :classification, :strategy, :tokens_used, :budget, :trace)
    end

    it 'supports keyword initialization' do
      result = Woods::Retriever::RetrievalResult.new(
        context: 'test',
        sources: [{ identifier: 'User' }],
        classification: classification,
        strategy: :hybrid,
        tokens_used: 500,
        budget: 4000
      )

      expect(result.context).to eq('test')
      expect(result.strategy).to eq(:hybrid)
      expect(result.budget).to eq(4000)
    end
  end

  # ── RetrievalTrace ──────────────────────────────────────────────

  describe 'RetrievalTrace' do
    it 'has all expected fields' do
      trace = Woods::Retriever::RetrievalTrace.new(
        classification: classification,
        strategy: :vector,
        candidate_count: 5,
        ranked_count: 3,
        tokens_used: 120,
        elapsed_ms: 42.5
      )

      expect(trace.classification).to eq(classification)
      expect(trace.strategy).to eq(:vector)
      expect(trace.candidate_count).to eq(5)
      expect(trace.ranked_count).to eq(3)
      expect(trace.tokens_used).to eq(120)
      expect(trace.elapsed_ms).to eq(42.5)
    end
  end

  describe 'trace in retrieve result' do
    it 'populates trace on retrieval result' do
      result = retriever.retrieve('How does the User model work?')

      expect(result.trace).to be_a(Woods::Retriever::RetrievalTrace)
      expect(result.trace.strategy).to eq(:vector)
      expect(result.trace.candidate_count).to eq(1)
      expect(result.trace.ranked_count).to eq(1)
      expect(result.trace.tokens_used).to eq(120)
      expect(result.trace.elapsed_ms).to be_a(Numeric)
      expect(result.trace.elapsed_ms).to be >= 0
    end

    it 'carries skipped_missing_metadata through from the assembled context' do
      stale_assembled_context = Woods::Retrieval::AssembledContext.new(
        context: assembled_context.context,
        tokens_used: 120,
        budget: 8000,
        sources: [],
        sections: [],
        skipped_missing_metadata: 1
      )
      allow(assembler_double).to receive(:assemble).and_return(stale_assembled_context)

      result = retriever.retrieve('How does the User model work?')

      expect(result.trace.skipped_missing_metadata).to eq(1)
    end

    it 'reports zero skipped_missing_metadata when the assembler resolved everything' do
      result = retriever.retrieve('How does the User model work?')

      expect(result.trace.skipped_missing_metadata).to eq(0)
    end
  end

  # ── #build_structural_context (private) ──────────────────────────

  describe 'structural context building' do
    it 'generates a codebase overview string' do
      allow(metadata_store).to receive(:count).and_return(42)
      allow(metadata_store).to receive(:find_by_type).with('model').and_return(Array.new(10))
      allow(metadata_store).to receive(:find_by_type).with('controller').and_return(Array.new(5))
      allow(metadata_store).to receive(:find_by_type).with('service').and_return(Array.new(8))
      allow(metadata_store).to receive(:find_by_type).with('job').and_return(Array.new(3))
      allow(metadata_store).to receive(:find_by_type).with('mailer').and_return(Array.new(2))
      allow(metadata_store).to receive(:find_by_type).with('component').and_return(Array.new(4))
      allow(metadata_store).to receive(:find_by_type).with('graphql').and_return(Array.new(6))

      result = retriever.send(:build_structural_context)

      expect(result).to include('Codebase: 42 searchable entries')
    end

    it 'includes type counts in overview' do
      allow(metadata_store).to receive(:count).and_return(20)
      allow(metadata_store).to receive(:find_by_type).with('model').and_return(Array.new(10))
      allow(metadata_store).to receive(:find_by_type).with('controller').and_return(Array.new(5))
      allow(metadata_store).to receive(:find_by_type).with('service').and_return(Array.new(3))
      allow(metadata_store).to receive(:find_by_type).with('job').and_return(Array.new(2))
      allow(metadata_store).to receive(:find_by_type).with('mailer').and_return([])
      allow(metadata_store).to receive(:find_by_type).with('component').and_return([])
      allow(metadata_store).to receive(:find_by_type).with('graphql').and_return([])

      result = retriever.send(:build_structural_context)

      expect(result).to include('10 model entries')
      expect(result).to include('5 controller entries')
      expect(result).to include('3 service entries')
      expect(result).to include('2 job entries')
    end

    it 'points at the structure tool as the canonical source for unit-level counts' do
      # #105 — searchable_entries (retriever) and units_indexed (manifest)
      # disagree because chunking duplicates long units. Without an
      # explicit pointer, operators reading the retriever banner can't
      # tell which number is authoritative for "did extraction capture
      # everything?"; the cross-reference resolves that.
      allow(metadata_store).to receive(:count).and_return(20)
      allow(metadata_store).to receive(:find_by_type).with('model').and_return(Array.new(10))
      allow(metadata_store).to receive(:find_by_type).with('controller').and_return(Array.new(5))
      allow(metadata_store).to receive(:find_by_type).with('service').and_return([])
      allow(metadata_store).to receive(:find_by_type).with('job').and_return([])
      allow(metadata_store).to receive(:find_by_type).with('mailer').and_return([])
      allow(metadata_store).to receive(:find_by_type).with('component').and_return([])
      allow(metadata_store).to receive(:find_by_type).with('graphql').and_return([])

      result = retriever.send(:build_structural_context)

      expect(result).to include('structure')
      expect(result).to match(/unit\s+counts?/i)
    end

    it 'omits types with zero count' do
      allow(metadata_store).to receive(:count).and_return(15)
      allow(metadata_store).to receive(:find_by_type).with('model').and_return(Array.new(10))
      allow(metadata_store).to receive(:find_by_type).with('controller').and_return(Array.new(5))
      allow(metadata_store).to receive(:find_by_type).with('service').and_return([])
      allow(metadata_store).to receive(:find_by_type).with('job').and_return([])
      allow(metadata_store).to receive(:find_by_type).with('mailer').and_return([])
      allow(metadata_store).to receive(:find_by_type).with('component').and_return([])
      allow(metadata_store).to receive(:find_by_type).with('graphql').and_return([])

      result = retriever.send(:build_structural_context)

      expect(result).not_to include('services')
      expect(result).not_to include('jobs')
      expect(result).not_to include('mailers')
      expect(result).not_to include('components')
      expect(result).not_to include('graphql')
    end

    it 'returns nil when total count is zero' do
      allow(metadata_store).to receive(:count).and_return(0)

      result = retriever.send(:build_structural_context)

      expect(result).to be_nil
    end

    it 'returns nil on error' do
      allow(metadata_store).to receive(:count).and_raise(StandardError, 'db connection failed')

      result = retriever.send(:build_structural_context)

      expect(result).to be_nil
    end
  end
end
