# frozen_string_literal: true

require 'spec_helper'
require 'codebase_index/retrieval/search_executor'
require 'codebase_index/retrieval/query_classifier'
require 'codebase_index/retrieval/context_assembler'
require 'codebase_index/storage/metadata_store'

RSpec.describe CodebaseIndex::Retrieval::ContextAssembler do
  let(:metadata_store) { instance_double(CodebaseIndex::Storage::MetadataStore::Interface) }
  let(:budget) { 8000 }
  let(:assembler) { described_class.new(metadata_store: metadata_store, budget: budget) }

  def candidate(identifier:, score:, source: :vector, metadata: {})
    CodebaseIndex::Retrieval::SearchExecutor::Candidate.new(
      identifier: identifier,
      score: score,
      source: source,
      metadata: metadata
    )
  end

  def classification(intent: :understand, scope: :focused, target_type: nil, framework_context: false)
    CodebaseIndex::Retrieval::QueryClassifier::Classification.new(
      intent: intent,
      scope: scope,
      target_type: target_type,
      framework_context: framework_context,
      keywords: []
    )
  end

  def unit_data(identifier:, type: :model, file_path: 'app/models/user.rb', source_code: 'class User; end')
    {
      identifier: identifier,
      type: type,
      file_path: file_path,
      source_code: source_code
    }
  end

  before do
    allow(metadata_store).to receive(:find).and_return(nil)
    # find_batch delegates to individual find stubs
    allow(metadata_store).to receive(:find_batch) do |ids|
      ids.each_with_object({}) do |id, result|
        data = metadata_store.find(id)
        result[id] = data if data
      end
    end
  end

  # ── #assemble ──────────────────────────────────────────────────────

  describe '#assemble' do
    it 'returns an AssembledContext struct' do
      result = assembler.assemble(candidates: [], classification: classification)

      expect(result).to be_a(CodebaseIndex::Retrieval::AssembledContext)
      expect(result).to respond_to(:context, :tokens_used, :budget, :sources, :sections)
    end

    it 'returns empty context for no candidates' do
      result = assembler.assemble(candidates: [], classification: classification)

      expect(result.context).to eq('')
      expect(result.tokens_used).to eq(0)
      expect(result.sources).to eq([])
    end

    it 'includes budget in result' do
      result = assembler.assemble(candidates: [], classification: classification)
      expect(result.budget).to eq(8000)
    end
  end

  # ── Structural context ─────────────────────────────────────────────

  describe 'structural context' do
    it 'places structural context first when provided' do
      allow(metadata_store).to receive(:find).with('User').and_return(
        unit_data(identifier: 'User')
      )

      result = assembler.assemble(
        candidates: [candidate(identifier: 'User', score: 0.9)],
        classification: classification,
        structural_context: '# Codebase Overview'
      )

      expect(result.sections.first).to eq(:structural)
      expect(result.context).to start_with('# Codebase Overview')
    end

    it 'works without structural context' do
      allow(metadata_store).to receive(:find).with('User').and_return(
        unit_data(identifier: 'User')
      )

      result = assembler.assemble(
        candidates: [candidate(identifier: 'User', score: 0.9)],
        classification: classification
      )

      expect(result.sections).not_to include(:structural)
    end
  end

  # ── Primary results ────────────────────────────────────────────────

  describe 'primary results' do
    it 'includes non-graph-expansion candidates in primary section' do
      allow(metadata_store).to receive(:find).with('User').and_return(
        unit_data(identifier: 'User', source_code: 'class User < ApplicationRecord; end')
      )

      result = assembler.assemble(
        candidates: [candidate(identifier: 'User', score: 0.9, source: :vector)],
        classification: classification
      )

      expect(result.sections).to include(:primary)
      expect(result.context).to include('User')
      expect(result.context).to include('class User')
    end

    it 'orders candidates by score within section' do
      allow(metadata_store).to receive(:find).with('First').and_return(
        unit_data(identifier: 'First', source_code: 'FIRST_CONTENT')
      )
      allow(metadata_store).to receive(:find).with('Second').and_return(
        unit_data(identifier: 'Second', source_code: 'SECOND_CONTENT')
      )

      result = assembler.assemble(
        candidates: [
          candidate(identifier: 'Second', score: 0.5),
          candidate(identifier: 'First', score: 0.9)
        ],
        classification: classification
      )

      first_pos = result.context.index('FIRST_CONTENT')
      second_pos = result.context.index('SECOND_CONTENT')
      expect(first_pos).to be < second_pos
    end

    it 'skips candidates not found in metadata store' do
      allow(metadata_store).to receive(:find).with('Missing').and_return(nil)
      allow(metadata_store).to receive(:find).with('Found').and_return(
        unit_data(identifier: 'Found', source_code: 'FOUND_CONTENT')
      )

      result = assembler.assemble(
        candidates: [
          candidate(identifier: 'Missing', score: 0.9),
          candidate(identifier: 'Found', score: 0.8)
        ],
        classification: classification
      )

      expect(result.context).to include('FOUND_CONTENT')
      source_ids = result.sources.map { |s| s[:identifier] }
      expect(source_ids).not_to include('Missing')
    end
  end

  # ── Supporting context ─────────────────────────────────────────────

  describe 'supporting context' do
    it 'separates graph_expansion candidates into supporting section' do
      allow(metadata_store).to receive(:find).with('Primary').and_return(
        unit_data(identifier: 'Primary', source_code: 'PRIMARY')
      )
      allow(metadata_store).to receive(:find).with('Expanded').and_return(
        unit_data(identifier: 'Expanded', source_code: 'EXPANDED')
      )

      result = assembler.assemble(
        candidates: [
          candidate(identifier: 'Primary', score: 0.9, source: :vector),
          candidate(identifier: 'Expanded', score: 0.5, source: :graph_expansion)
        ],
        classification: classification
      )

      expect(result.sections).to include(:primary, :supporting)
      expect(result.context).to include('PRIMARY')
      expect(result.context).to include('EXPANDED')
    end
  end

  # ── Framework context ──────────────────────────────────────────────

  describe 'framework context' do
    it 'includes framework section when classification has framework_context' do
      allow(metadata_store).to receive(:find).with('RailsSource').and_return(
        unit_data(identifier: 'RailsSource', type: :rails_source, source_code: 'FRAMEWORK')
      )

      result = assembler.assemble(
        candidates: [
          candidate(identifier: 'RailsSource', score: 0.8, metadata: { type: 'rails_source' })
        ],
        classification: classification(framework_context: true)
      )

      expect(result.sections).to include(:framework)
      expect(result.context).to include('FRAMEWORK')
    end

    it 'excludes framework section when classification lacks framework_context' do
      allow(metadata_store).to receive(:find).with('RailsSource').and_return(
        unit_data(identifier: 'RailsSource', type: :rails_source, source_code: 'FRAMEWORK')
      )

      result = assembler.assemble(
        candidates: [
          candidate(identifier: 'RailsSource', score: 0.8, metadata: { type: 'rails_source' })
        ],
        classification: classification(framework_context: false)
      )

      expect(result.sections).not_to include(:framework)
    end
  end

  # ── Token budget ───────────────────────────────────────────────────

  describe 'token budget' do
    it 'respects total token budget' do
      # Create a unit with known large content
      large_source = 'x' * 50_000 # ~14,286 tokens
      allow(metadata_store).to receive(:find).with('Large').and_return(
        unit_data(identifier: 'Large', source_code: large_source)
      )

      result = assembler.assemble(
        candidates: [candidate(identifier: 'Large', score: 0.9)],
        classification: classification
      )

      expect(result.tokens_used).to be <= budget + 100 # small overhead tolerance
    end

    it 'truncates content when it exceeds section budget' do
      large_source = 'x' * 50_000
      allow(metadata_store).to receive(:find).with('Large').and_return(
        unit_data(identifier: 'Large', source_code: large_source)
      )

      result = assembler.assemble(
        candidates: [candidate(identifier: 'Large', score: 0.9)],
        classification: classification
      )

      expect(result.context).to include('... [truncated]')
    end

    it 'fits multiple candidates within budget' do
      %w[A B C].each do |id|
        allow(metadata_store).to receive(:find).with(id).and_return(
          unit_data(identifier: id, source_code: "class #{id}; end")
        )
      end

      result = assembler.assemble(
        candidates: [
          candidate(identifier: 'A', score: 0.9),
          candidate(identifier: 'B', score: 0.8),
          candidate(identifier: 'C', score: 0.7)
        ],
        classification: classification
      )

      expect(result.context).to include('class A', 'class B', 'class C')
      expect(result.sources.size).to eq(3)
    end

    it 'uses custom budget when provided' do
      small_assembler = described_class.new(metadata_store: metadata_store, budget: 500)

      allow(metadata_store).to receive(:find).with('Unit').and_return(
        unit_data(identifier: 'Unit', source_code: 'x' * 5000)
      )

      result = small_assembler.assemble(
        candidates: [candidate(identifier: 'Unit', score: 0.9)],
        classification: classification
      )

      expect(result.budget).to eq(500)
      expect(result.context).to include('... [truncated]')
    end

    it 'overrides instance budget when budget: keyword arg is passed to assemble' do
      # Assembler initialized with 8000, but caller passes 2000
      allow(metadata_store).to receive(:find).with('Unit').and_return(
        unit_data(identifier: 'Unit', source_code: 'class Unit; end')
      )

      result = assembler.assemble(
        candidates: [candidate(identifier: 'Unit', score: 0.9)],
        classification: classification,
        budget: 2000
      )

      expect(result.budget).to eq(2000)
    end

    it 'falls back to instance budget when budget: keyword arg is nil' do
      allow(metadata_store).to receive(:find).with('Unit').and_return(
        unit_data(identifier: 'Unit', source_code: 'class Unit; end')
      )

      result = assembler.assemble(
        candidates: [candidate(identifier: 'Unit', score: 0.9)],
        classification: classification,
        budget: nil
      )

      expect(result.budget).to eq(8000)
    end
  end

  # ── Source attribution ─────────────────────────────────────────────

  describe 'source attribution' do
    it 'includes identifier, type, score, and file_path in sources' do
      allow(metadata_store).to receive(:find).with('User').and_return(
        unit_data(identifier: 'User', type: :model, file_path: 'app/models/user.rb')
      )

      result = assembler.assemble(
        candidates: [candidate(identifier: 'User', score: 0.85)],
        classification: classification
      )

      source = result.sources.first
      expect(source[:identifier]).to eq('User')
      expect(source[:type]).to eq(:model)
      expect(source[:score]).to eq(0.85)
      expect(source[:file_path]).to eq('app/models/user.rb')
    end

    it 'marks truncated sources' do
      large_source = 'x' * 50_000
      allow(metadata_store).to receive(:find).with('Large').and_return(
        unit_data(identifier: 'Large', source_code: large_source)
      )

      result = assembler.assemble(
        candidates: [candidate(identifier: 'Large', score: 0.9)],
        classification: classification
      )

      truncated_sources = result.sources.select { |s| s[:truncated] }
      expect(truncated_sources).not_to be_empty
    end
  end

  # ── Deduplication ──────────────────────────────────────────────────

  describe 'deduplication' do
    it 'includes source attribution for each section a candidate appears in' do
      allow(metadata_store).to receive(:find).with('User').and_return(
        unit_data(identifier: 'User')
      )

      result = assembler.assemble(
        candidates: [
          candidate(identifier: 'User', score: 0.9, source: :vector),
          candidate(identifier: 'User', score: 0.7, source: :graph_expansion)
        ],
        classification: classification
      )

      # User appears in both primary and supporting sections
      identifiers = result.sources.map { |s| s[:identifier] }
      expect(identifiers).to include('User')
    end
  end

  # ── Section ordering ───────────────────────────────────────────────

  describe 'section ordering' do
    it 'orders: structural, primary, supporting, framework' do
      allow(metadata_store).to receive(:find).with('Primary').and_return(
        unit_data(identifier: 'Primary', source_code: 'PRIMARY_CONTENT')
      )
      allow(metadata_store).to receive(:find).with('Expanded').and_return(
        unit_data(identifier: 'Expanded', source_code: 'EXPANDED_CONTENT')
      )
      allow(metadata_store).to receive(:find).with('Framework').and_return(
        unit_data(identifier: 'Framework', type: :rails_source, source_code: 'FRAMEWORK_CONTENT')
      )

      result = assembler.assemble(
        candidates: [
          candidate(identifier: 'Primary', score: 0.9, source: :vector),
          candidate(identifier: 'Expanded', score: 0.5, source: :graph_expansion),
          candidate(identifier: 'Framework', score: 0.7, source: :graph_expansion,
                    metadata: { type: 'rails_source' })
        ],
        classification: classification(framework_context: true),
        structural_context: 'STRUCTURAL_OVERVIEW'
      )

      expect(result.sections).to eq(%i[structural primary supporting framework])

      # Verify structural comes before primary
      structural_pos = result.context.index('STRUCTURAL_OVERVIEW')
      primary_pos = result.context.index('PRIMARY_CONTENT')
      expect(structural_pos).to be < primary_pos
    end
  end

  # ── Constants ──────────────────────────────────────────────────────

  describe 'constants' do
    it 'has default budget of 8000 tokens' do
      expect(described_class::DEFAULT_BUDGET).to eq(8000)
    end

    it 'has budget allocation summing to 1.0' do
      expect(described_class::BUDGET_ALLOCATION.values.sum).to be_within(0.001).of(1.0)
    end

    it 'has minimum useful tokens threshold' do
      expect(described_class::MIN_USEFUL_TOKENS).to eq(200)
    end
  end
end
