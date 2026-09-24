# frozen_string_literal: true

require_relative '../token_utils'
require_relative 'input_budget'

module Woods
  module Embedding
    # Prepares ExtractedUnit data for embedding by building context-prefixed text.
    #
    # Follows the context prefix format (see `git log --follow -- docs/design/CONTEXT_AND_CHUNKING.md`):
    #   [type] identifier
    #   namespace: ...
    #   file: ...
    #   dependencies: dep1, dep2, ...
    #
    # Refuses oversized direct inputs; the indexing path splits complete inputs
    # without truncation before submitting them to the provider.
    #
    # @example
    #   preparer = Woods::Embedding::TextPreparer.new(max_tokens: 8192)
    #   text = preparer.prepare(unit)
    #   chunks = preparer.prepare_chunks(unit)
    class TextPreparer
      DEFAULT_MAX_TOKENS = 8192
      # Aliased to the single source of truth in {Woods::TokenUtils} so the
      # OpenAI 4.0 / Ollama 1.5 ratios stay consistent across TextPreparer,
      # ContextAssembler, Builder, and cost_model/. See
      # docs/TOKEN_BENCHMARK.md and lib/woods/token_utils.rb.
      DEFAULT_CHARS_PER_TOKEN = TokenUtils::DEFAULT_CHARS_PER_TOKEN

      # @param max_tokens [Integer] maximum token budget for prepared text
      # @param chars_per_token [Float] tokenizer-calibrated char/token ratio
      def initialize(max_tokens: DEFAULT_MAX_TOKENS, chars_per_token: DEFAULT_CHARS_PER_TOKEN, input_budget: nil)
        @max_tokens = max_tokens
        @chars_per_token = chars_per_token
        @input_budget = input_budget || InputBudget.new(limit: max_tokens, chars_per_token: chars_per_token)
      end

      # @return [Float] configured chars-per-token ratio
      attr_reader :chars_per_token

      # @return [Integer] configured token budget
      attr_reader :max_tokens

      # Prepare text for embedding from an ExtractedUnit.
      #
      # Builds a context prefix and appends the unit's source code (or first
      # chunk content for chunked units). Refuses inputs exceeding the configured limit.
      #
      # @param unit [Woods::ExtractedUnit] the unit to prepare
      # @return [String] context-prefixed text ready for embedding
      def prepare(unit, budget: @input_budget)
        prefix = build_prefix(unit)
        content = select_content(unit)
        text = "#{prefix}\n#{content}"
        budget.validate!(text)
      end

      # Prepare text for each chunk of an ExtractedUnit.
      #
      # If the unit has no chunks, returns a single-element array with the
      # full prepared text. For chunked units, each chunk gets the same
      # context prefix prepended.
      #
      # @param unit [Woods::ExtractedUnit] the unit to prepare
      # @return [Array<String>] array of context-prefixed texts
      def prepare_chunks(unit, budget: @input_budget)
        return [prepare(unit, budget: budget)] unless unit.chunks&.any?

        prefix = build_prefix(unit)
        unit.chunks.map do |chunk|
          text = "#{prefix}\n#{chunk[:content]}"
          budget.validate!(text)
        end
      end

      # Fit complete prefixed inputs without removing any source characters.
      # Existing chunk attributes survive; embedding_slice records byte offsets
      # relative to the original chunk for downstream physical-source attribution.
      def prepare_for_embedding(unit, budget: @input_budget)
        prefix = "#{build_prefix(unit)}\n"
        unless budget.fits?(prefix)
          raise InputLimitError, "Embedding prefix exceeds input limit (#{budget.method}: #{budget.count(prefix)})"
        end

        originals = unit.chunks.any? ? unit.chunks : [{ content: unit.source_code || '', chunk_type: :whole }]
        fitted = originals.flat_map { |chunk| fit_chunk(chunk, prefix, budget) }
        unit.chunks = fitted if unit.chunks.any? || fitted.size > 1
        prepare_chunks(unit, budget: budget)
      end

      def preparation_identity
        { 'class' => self.class.name, 'version' => 1, 'budget' => @input_budget.identity }
      end

      private

      def fit_chunk(chunk, prefix, budget)
        content = chunk[:content].to_s
        return [chunk] if budget.fits?(prefix + content)

        offset = chunk.dig(:embedding_slice, :start_byte) || 0
        split_content(content, prefix, budget).map do |part|
          first = offset
          offset += part.bytesize
          chunk.merge(content: part, embedding_slice: { start_byte: first, end_byte: offset })
        end
      end

      def split_content(content, prefix, budget)
        return [content] if budget.fits?(prefix + content)
        if content.length <= 1
          raise InputLimitError, 'Embedding input limit leaves no room for one source character after the prefix'
        end

        middle = content.length / 2
        split_content(content[0...middle], prefix, budget) + split_content(content[middle..], prefix, budget)
      end

      # Build the context prefix for a unit.
      #
      # @param unit [Woods::ExtractedUnit] the unit
      # @return [String] formatted prefix lines
      def build_prefix(unit)
        lines = []
        lines << "[#{unit.type}] #{unit.identifier}"
        lines << "namespace: #{unit.namespace}" if unit.namespace
        lines << "file: #{unit.file_path}" if unit.file_path
        append_dependency_line(lines, unit.dependencies)
        lines.join("\n")
      end

      # Append a formatted dependency line if dependencies exist.
      #
      # @param lines [Array<String>] lines to append to
      # @param dependencies [Array<Hash>, nil] dependency list
      # @return [void]
      def append_dependency_line(lines, dependencies)
        return unless dependencies&.any?

        # Dependency hashes arrive symbol-keyed from the extractor's
        # in-memory units but string-keyed from the indexer (Indexer#build_unit
        # reads JSON and does not symbolize dependency keys, unlike chunks).
        # Read both forms or the whole "dependencies:" prefix silently
        # vanishes from every embedded document on the indexing path.
        dep_names = dependencies.filter_map { |d| d.is_a?(String) ? d : d[:target] || d['target'] }.first(10)
        lines << "dependencies: #{dep_names.join(', ')}" if dep_names.any?
      end

      # Select the content to embed for a unit.
      #
      # @param unit [Woods::ExtractedUnit] the unit
      # @return [String] source code or first chunk content
      def select_content(unit)
        if unit.chunks&.any?
          unit.chunks.first[:content]
        else
          unit.source_code || ''
        end
      end
    end
  end
end
