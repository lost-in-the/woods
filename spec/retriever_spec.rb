# frozen_string_literal: true

require 'spec_helper'
require 'codebase_index'
require 'codebase_index/retriever'

RSpec.describe CodebaseIndex::Retriever do
  let(:vector_store) { instance_double('VectorStore') }
  let(:metadata_store) { instance_double('MetadataStore') }
  let(:graph_store) { instance_double('GraphStore') }
  let(:embedding_provider) { instance_double('EmbeddingProvider') }
  let(:formatter) { nil }

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
    CodebaseIndex::Retrieval::QueryClassifier::Classification.new(
      intent: :understand,
      scope: :focused,
      target_type: :model,
      framework_context: false,
      keywords: %w[user model]
    )
  end

  let(:candidates) do
    [
      CodebaseIndex::Retrieval::SearchExecutor::Candidate.new(
        identifier: 'User', score: 0.9, source: :vector, metadata: { type: 'model' }
      )
    ]
  end

  let(:execution_result) do
    CodebaseIndex::Retrieval::SearchExecutor::ExecutionResult.new(
      candidates: candidates,
      strategy: :vector,
      query: 'How does the User model work?'
    )
  end

  let(:ranked_candidates) { candidates }

  let(:assembled_context) do
    CodebaseIndex::Retrieval::AssembledContext.new(
      context: '## User (model)\nclass User < ApplicationRecord; end',
      tokens_used: 120,
      budget: 8000,
      sources: [{ identifier: 'User', type: :model, score: 0.9, file_path: 'app/models/user.rb' }],
      sections: %i[structural primary]
    )
  end

  before do
    allow_any_instance_of(CodebaseIndex::Retrieval::QueryClassifier)
      .to receive(:classify).and_return(classification)
    allow_any_instance_of(CodebaseIndex::Retrieval::SearchExecutor)
      .to receive(:execute).and_return(execution_result)
    allow_any_instance_of(CodebaseIndex::Retrieval::Ranker)
      .to receive(:rank).and_return(ranked_candidates)
    allow_any_instance_of(CodebaseIndex::Retrieval::ContextAssembler)
      .to receive(:assemble).and_return(assembled_context)

    # build_structural_context calls metadata_store.count; default to 0 (nil result)
    allow(metadata_store).to receive(:count).and_return(0)
  end

  # ── #retrieve ──────────────────────────────────────────────────────

  describe '#retrieve' do
    it 'returns a RetrievalResult' do
      result = retriever.retrieve('How does the User model work?')

      expect(result).to be_a(CodebaseIndex::Retriever::RetrievalResult)
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
      expect_any_instance_of(CodebaseIndex::Retrieval::ContextAssembler)
        .to receive(:assemble)
        .with(hash_including(structural_context: anything))
        .and_return(assembled_context)

      retriever.retrieve('How does the User model work?', budget: 4000)
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

  # ── Pipeline integration ─────────────────────────────────────────

  describe 'pipeline flow' do
    it 'calls classify, execute, rank, assemble in sequence' do
      classifier_double = instance_double(CodebaseIndex::Retrieval::QueryClassifier)
      executor_double = instance_double(CodebaseIndex::Retrieval::SearchExecutor)
      ranker_double = instance_double(CodebaseIndex::Retrieval::Ranker)
      assembler_double = instance_double(CodebaseIndex::Retrieval::ContextAssembler)

      allow(CodebaseIndex::Retrieval::QueryClassifier).to receive(:new).and_return(classifier_double)
      allow(CodebaseIndex::Retrieval::SearchExecutor).to receive(:new).and_return(executor_double)
      allow(CodebaseIndex::Retrieval::Ranker).to receive(:new).and_return(ranker_double)
      allow(CodebaseIndex::Retrieval::ContextAssembler).to receive(:new).and_return(assembler_double)

      expect(classifier_double).to receive(:classify).with('test query').and_return(classification).ordered
      expect(executor_double).to receive(:execute)
        .with(query: 'test query', classification: classification)
        .and_return(execution_result).ordered
      expect(ranker_double).to receive(:rank)
        .with(candidates, classification: classification)
        .and_return(ranked_candidates).ordered
      expect(assembler_double).to receive(:assemble)
        .with(candidates: ranked_candidates, classification: classification, structural_context: anything)
        .and_return(assembled_context).ordered

      # Need to allow metadata_store calls for structural context
      allow(metadata_store).to receive(:count).and_return(0)

      fresh_retriever = described_class.new(
        vector_store: vector_store,
        metadata_store: metadata_store,
        graph_store: graph_store,
        embedding_provider: embedding_provider
      )

      fresh_retriever.retrieve('test query')
    end
  end

  # ── RetrievalResult struct ───────────────────────────────────────

  describe 'RetrievalResult' do
    it 'has all expected fields' do
      result = CodebaseIndex::Retriever::RetrievalResult.new(
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
      result = CodebaseIndex::Retriever::RetrievalResult.new(
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
      trace = CodebaseIndex::Retriever::RetrievalTrace.new(
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

      expect(result.trace).to be_a(CodebaseIndex::Retriever::RetrievalTrace)
      expect(result.trace.strategy).to eq(:vector)
      expect(result.trace.candidate_count).to eq(1)
      expect(result.trace.ranked_count).to eq(1)
      expect(result.trace.tokens_used).to eq(120)
      expect(result.trace.elapsed_ms).to be_a(Numeric)
      expect(result.trace.elapsed_ms).to be >= 0
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

      expect(result).to include('Codebase: 42 units')
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

      expect(result).to include('10 models')
      expect(result).to include('5 controllers')
      expect(result).to include('3 services')
      expect(result).to include('2 jobs')
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
