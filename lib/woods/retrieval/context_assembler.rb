# frozen_string_literal: true

require_relative 'search_executor'
require_relative '../token_utils'

module Woods
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

      # Default chars-per-token ratio. Delegates to {Woods::TokenUtils} —
      # the single source of truth — which uses 4.0 (OpenAI / tiktoken
      # cl100k_base average for Ruby source; see docs/TOKEN_BENCHMARK.md).
      # Callers embedding with BERT/WordPiece tokenizers (nomic-embed-text,
      # bge-*) should pass the tighter ratio from their TextPreparer
      # (~1.5–2.5) so truncation stays honest for that provider — or use
      # {TokenUtils.chars_per_token_for(:ollama)} for the shipped default.
      DEFAULT_CHARS_PER_TOKEN = TokenUtils::DEFAULT_CHARS_PER_TOKEN

      # @param metadata_store [#find] Store that resolves identifiers to unit data
      # @param budget [Integer] Total token budget
      # @param chars_per_token [Float] Tokenizer-calibrated char/token ratio used
      #   for truncation sizing. Match this to the embedding provider in use —
      #   {Woods::Embedding::TextPreparer#chars_per_token} exposes the live
      #   value from the indexing-time preparer.
      # @param token_counter [#count, nil] Optional exact tokenizer (typically
      #   {Woods::Embedding::TokenCounter}). When provided, token estimation
      #   uses the model's real WordPiece/BPE output instead of the
      #   `chars / chars_per_token` heuristic, which matters most for the
      #   Ollama path (ratios vary widely across Rails source, 1.5–2.5).
      #   The heuristic remains the fallback when the counter is nil or the
      #   tokenizer gem isn't installed.
      def initialize(metadata_store:, budget: DEFAULT_BUDGET,
                     chars_per_token: DEFAULT_CHARS_PER_TOKEN,
                     token_counter: nil)
        @metadata_store = metadata_store
        @budget = budget
        # Guard against 0 / negative / NaN ratios — any of those would make
        # `estimate_tokens` div-by-zero or return a negative budget, which
        # would silently truncate every section to empty. Fall back to the
        # default ratio rather than propagate the bogus input.
        ratio = chars_per_token.to_f
        @chars_per_token = ratio.positive? ? ratio : DEFAULT_CHARS_PER_TOKEN
        @token_counter = token_counter
      end

      # @return [Float] the configured chars-per-token ratio
      attr_reader :chars_per_token

      # @return [#count, nil] the exact tokenizer, if one was injected
      attr_reader :token_counter

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

        # Collapse +User#chunk_0+, +User#chunk_1+, … back to their base unit
        # BEFORE metadata lookup and section assembly. Chunk IDs are an
        # embedding-side concern — the metadata store is keyed by the base
        # identifier, and callers don't want the same unit formatted twice
        # just because multiple chunks matched the query.
        candidates = collapse_chunk_candidates(candidates)

        # Pre-fetch all candidate metadata in one batch query
        @unit_cache = @metadata_store.find_batch(candidates.map(&:identifier))

        # 1. Structural context (always first if provided)
        tokens_used = add_structural_section(sections, structural_context, tokens_used, effective_budget)

        # 2. Compute per-section budgets from remaining tokens
        budgets = compute_section_budgets(effective_budget - tokens_used, classification)

        # 3. Primary, supporting, and framework sections
        add_result_sections(sections, sources, candidates, budgets)

        build_result(sections, sources, effective_budget)
      end

      private

      # Suffix the Indexer appends when a single unit is split into multiple
      # embedding vectors (rails_source and other large units). Separator
      # is +#+ so it can never collide with a Ruby constant (+::+) or a
      # method ref (+#instance_method+) in an identifier.
      CHUNK_SUFFIX_PATTERN = /#chunk_\d+\z/
      private_constant :CHUNK_SUFFIX_PATTERN

      # Strip the +#chunk_N+ suffix from an identifier, if present.
      # +User#chunk_3+ → +User+; +User+ stays +User+.
      def base_identifier(identifier)
        identifier.sub(CHUNK_SUFFIX_PATTERN, '')
      end

      # Rewrite every candidate to point at its base identifier and keep only
      # the highest-scoring candidate per base unit. Preserves original score
      # ordering on the output so downstream +sort_by(-score)+ gets the same
      # input it would on an unchunked corpus.
      def collapse_chunk_candidates(candidates)
        best = {}
        candidates.each do |c|
          base = base_identifier(c.identifier)
          rewritten = c.identifier == base ? c : rewrite_identifier(c, base)
          best[base] = rewritten if best[base].nil? || rewritten.score > best[base].score
        end
        best.values
      end

      # Return a clone of +candidate+ with its identifier replaced. Kept as
      # its own method so the Candidate struct shape is referenced in exactly
      # one place — if SearchExecutor::Candidate grows fields, this is the
      # only spot to update.
      def rewrite_identifier(candidate, new_identifier)
        SearchExecutor::Candidate.new(
          identifier: new_identifier,
          score: candidate.score,
          source: candidate.source,
          metadata: candidate.metadata,
          matched_fields: candidate.matched_fields
        )
      end

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

      # Partition candidates into the primary/supporting/framework sections
      # and append each section's content.
      #
      # The three sections are a strict PARTITION, not overlapping selects.
      # When the framework budget is active, framework-source candidates
      # (rails_source / gem_source) are formatted ONLY in the framework
      # section — previously a vector-sourced rails_source hit landed in
      # primary AND framework, spending both budgets on the same source
      # text (#186 / B-074). When the framework budget is zero (no
      # framework context), framework candidates stay in their natural
      # primary/supporting bucket, preserving the pre-fix behaviour.
      #
      # @param sections [Array<Hash>] Section accumulator (mutated)
      # @param sources [Array<Hash>] Source-attribution accumulator (mutated)
      # @param candidates [Array<Candidate>] Ranked, chunk-collapsed candidates
      # @param budgets [Hash<Symbol, Integer>] Per-section token budgets
      # @return [void]
      def add_result_sections(sections, sources, candidates, budgets)
        framework_active = budgets[:framework].positive?
        framework, local = if framework_active
                             candidates.partition { |c| framework_candidate?(c) }
                           else
                             [[], candidates]
                           end

        add_candidate_section(sections, sources, :primary,
                              local.reject { |c| c.source == :graph_expansion }, budgets[:primary])
        add_candidate_section(sections, sources, :supporting,
                              local.select { |c| c.source == :graph_expansion }, budgets[:supporting])
        add_candidate_section(sections, sources, :framework, framework, budgets[:framework]) if framework_active
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
        identifier = unit_field(unit, :identifier)
        type = unit_field(unit, :type)
        file_path = unit_field(unit, :file_path)
        source = unit_field(unit, :source_code) || ''

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
          type: unit_field(unit, :type),
          score: candidate.score,
          file_path: unit_field(unit, :file_path)
        }
        attribution[:truncated] = true if truncated
        attribution
      end

      # Read a field from a unit hash, accepting either symbol or string keys.
      #
      # @param unit [Hash]
      # @param key [Symbol]
      # @return [Object, nil]
      def unit_field(unit, key)
        unit[key] || unit[key.to_s]
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

        # Target-char sizing uses the effective ratio: the provider's live
        # ratio when we have an exact counter, otherwise @chars_per_token.
        # 10 % safety margin keeps us below the budget after the imprecise
        # tokenizer runs again on the truncated output.
        target_chars = (token_budget * effective_chars_per_token * 0.9).to_i
        "#{text[0...target_chars]}\n... [truncated]"
      end

      # Estimate token count. Prefers the injected {TokenCounter} — which
      # loads the provider's real tokenizer and returns exact counts — and
      # falls back to the configured chars-per-token ratio when no counter
      # is wired.
      #
      # @param text [String]
      # @return [Integer]
      def estimate_tokens(text)
        return 0 if text.nil? || text.empty?
        return @token_counter.count(text) if @token_counter

        (text.length / @chars_per_token).ceil
      end

      # Effective chars-per-token for chunk-size sizing. When an exact
      # counter is present, prefer its native ratio (e.g. 1.2 for
      # nomic-embed-text) so truncation and estimation agree. Falls back
      # to the configured ratio if the counter reports 0 or a non-positive
      # value (which would make truncation target zero chars).
      def effective_chars_per_token
        if @token_counter.respond_to?(:chars_per_token) && @token_counter.chars_per_token
          ratio = @token_counter.chars_per_token.to_f
          return ratio if ratio.positive?
        end
        @chars_per_token
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
