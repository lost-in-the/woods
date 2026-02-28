# frozen_string_literal: true

module CodebaseIndex
  module Retrieval
    # Transforms ranked search candidates into a token-budgeted context string
    # for LLM consumption.
    #
    # Allocates a fixed token budget across four sections:
    # - Structural (10%): Always-included codebase overview
    # - Primary (50%): Direct query results
    # - Supporting (25%): Dependencies and related context
    # - Framework (15%): Rails/gem source when query has framework context
    #
    # When framework context is not needed, primary and supporting sections
    # receive the framework allocation proportionally.
    #
    # @example
    #   assembler = ContextAssembler.new(metadata_store: store)
    #   result = assembler.assemble(candidates: ranked, classification: cls)
    #   result.context     # => "## User (model)\n..."
    #   result.tokens_used # => 4200
    #   result.sections    # => [:structural, :primary, :supporting]
    #
    class ContextAssembler
      DEFAULT_BUDGET = 8000 # tokens

      BUDGET_ALLOCATION = {
        structural: 0.10,
        primary: 0.50,
        supporting: 0.25,
        framework: 0.15
      }.freeze

      # Minimum token count for a section to be worth including.
      MIN_USEFUL_TOKENS = 200

      # @param metadata_store [#find] Store that resolves identifiers to unit data
      # @param budget [Integer] Total token budget
      def initialize(metadata_store:, budget: DEFAULT_BUDGET)
        @metadata_store = metadata_store
        @budget = budget
      end

      # Assemble context from ranked candidates within token budget.
      #
      # @param candidates [Array<Candidate>] Ranked search candidates
      # @param classification [QueryClassifier::Classification] Query classification
      # @param structural_context [String, nil] Optional codebase overview text
      # @param budget [Integer, nil] Override token budget; falls back to @budget
      # @return [AssembledContext] Token-budgeted context with source attribution
      def assemble(candidates:, classification:, structural_context: nil, budget: nil)
        effective_budget = budget || @budget
        sections = []
        sources = []
        tokens_used = 0

        # Pre-fetch all candidate metadata in one batch query
        @unit_cache = @metadata_store.find_batch(candidates.map(&:identifier))

        # 1. Structural context (always first if provided)
        tokens_used = add_structural_section(sections, structural_context, tokens_used, effective_budget)

        # 2. Compute per-section budgets from remaining tokens
        budgets = compute_section_budgets(effective_budget - tokens_used, classification)

        # 3. Primary, supporting, and framework sections
        add_candidate_section(sections, sources, :primary,
                              candidates.reject { |c| c.source == :graph_expansion }, budgets[:primary])
        add_candidate_section(sections, sources, :supporting,
                              candidates.select { |c| c.source == :graph_expansion }, budgets[:supporting])
        if budgets[:framework].positive?
          add_candidate_section(sections, sources, :framework,
                                candidates.select { |c| framework_candidate?(c) }, budgets[:framework])
        end

        build_result(sections, sources, effective_budget)
      end

      private

      # Add structural context section if provided.
      #
      # @return [Integer] Updated tokens_used count
      def add_structural_section(sections, structural_context, tokens_used, effective_budget)
        return tokens_used unless structural_context

        budget = (effective_budget * BUDGET_ALLOCATION[:structural]).to_i
        text = truncate_to_budget(structural_context, budget)
        sections << { section: :structural, content: text }
        tokens_used + estimate_tokens(text)
      end

      # Add a candidate-based section if candidates produce content.
      #
      # @return [void]
      def add_candidate_section(sections, sources, section_name, candidates, budget)
        return if candidates.empty?

        content, section_sources = assemble_section(candidates, budget)
        return if content.empty?

        sections << { section: section_name, content: content }
        sources.concat(section_sources)
      end

      # Compute token budgets for primary/supporting/framework sections.
      #
      # @param remaining [Integer] Tokens available after structural
      # @param classification [QueryClassifier::Classification]
      # @return [Hash<Symbol, Integer>]
      def compute_section_budgets(remaining, classification)
        if classification.framework_context
          {
            primary: (remaining * 0.55).to_i,
            supporting: (remaining * 0.25).to_i,
            framework: (remaining * 0.20).to_i
          }
        else
          {
            primary: (remaining * 0.65).to_i,
            supporting: (remaining * 0.35).to_i,
            framework: 0
          }
        end
      end

      # Assemble content for a single section within a token budget.
      #
      # @param candidates [Array<Candidate>] Candidates for this section
      # @param budget [Integer] Token budget for this section
      # @return [Array(String, Array<Hash>)] Content string and source attributions
      def assemble_section(candidates, budget)
        content_parts = []
        sources = []
        tokens_used = 0

        candidates.sort_by { |c| -c.score }.each do |candidate|
          tokens_used = append_candidate(content_parts, sources, candidate, budget, tokens_used)
          break if tokens_used.nil?
        end

        [content_parts.join("\n\n"), sources]
      end

      # Append a single candidate to the section. Returns updated tokens_used, or nil to stop.
      def append_candidate(parts, sources, candidate, budget, tokens_used)
        unit = @unit_cache[candidate.identifier]
        return tokens_used unless unit

        text = format_unit(unit, candidate)
        tokens = estimate_tokens(text)
        remaining = budget - tokens_used

        if tokens <= remaining
          parts << text
          sources << build_source_attribution(candidate, unit)
          tokens_used + tokens
        elsif remaining > MIN_USEFUL_TOKENS
          parts << truncate_to_budget(text, remaining)
          sources << build_source_attribution(candidate, unit, truncated: true)
          nil
        end
      end

      # Format a unit for inclusion in context.
      #
      # @param unit [Hash] Unit data from metadata store
      # @param candidate [Candidate] The search candidate
      # @return [String]
      def format_unit(unit, _candidate)
        identifier = unit[:identifier] || unit['identifier']
        type = unit[:type] || unit['type']
        file_path = unit[:file_path] || unit['file_path']
        source = unit[:source_code] || unit['source_code'] || ''

        <<~UNIT.strip
          ## #{identifier} (#{type})
          File: #{file_path}

          #{source}
        UNIT
      end

      # Build source attribution hash for a candidate.
      #
      # @return [Hash]
      def build_source_attribution(candidate, unit, truncated: false)
        attribution = {
          identifier: candidate.identifier,
          type: unit[:type] || unit['type'],
          score: candidate.score,
          file_path: unit[:file_path] || unit['file_path']
        }
        attribution[:truncated] = true if truncated
        attribution
      end

      # Check if a candidate is framework source.
      #
      # @param candidate [Candidate]
      # @return [Boolean]
      def framework_candidate?(candidate)
        metadata = candidate.metadata
        return false unless metadata

        type = metadata[:type] || metadata['type']
        %w[rails_source gem_source].include?(type.to_s)
      end

      # Truncate text to fit within a token budget.
      #
      # @param text [String]
      # @param token_budget [Integer]
      # @return [String]
      def truncate_to_budget(text, token_budget)
        return text if estimate_tokens(text) <= token_budget

        # Estimate target character count with 10% safety margin
        target_chars = (token_budget * 4.0 * 0.9).to_i
        "#{text[0...target_chars]}\n... [truncated]"
      end

      # Estimate token count using the project convention.
      #
      # @param text [String]
      # @return [Integer]
      def estimate_tokens(text)
        (text.length / 4.0).ceil
      end

      # Build the final AssembledContext result.
      #
      # @param sections [Array<Hash>] Assembled sections
      # @param sources [Array<Hash>] Source attributions
      # @param effective_budget [Integer] The budget actually used for assembly
      # @return [AssembledContext]
      def build_result(sections, sources, effective_budget)
        context = sections.map { |s| s[:content] }.join("\n\n---\n\n")
        AssembledContext.new(
          context: context,
          tokens_used: estimate_tokens(context),
          budget: effective_budget,
          sources: sources.uniq,
          sections: sections.map { |s| s[:section] }
        )
      end
    end

    # Result of context assembly.
    AssembledContext = Struct.new(:context, :tokens_used, :budget, :sources, :sections, keyword_init: true)
  end
end
