# frozen_string_literal: true

require_relative '../token_utils'

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
    # Handles token limit enforcement by truncating text that exceeds the
    # embedding model's context window.
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
      def initialize(max_tokens: DEFAULT_MAX_TOKENS, chars_per_token: DEFAULT_CHARS_PER_TOKEN)
        @max_tokens = max_tokens
        @chars_per_token = chars_per_token
      end

      # @return [Float] configured chars-per-token ratio
      attr_reader :chars_per_token

      # @return [Integer] configured token budget
      attr_reader :max_tokens

      # Prepare text for embedding from an ExtractedUnit.
      #
      # Builds a context prefix and appends the unit's source code (or first
      # chunk content for chunked units). Enforces token limits via truncation.
      #
      # @param unit [Woods::ExtractedUnit] the unit to prepare
      # @return [String] context-prefixed text ready for embedding
      def prepare(unit)
        prefix = build_prefix(unit)
        content = select_content(unit)
        text = "#{prefix}\n#{content}"
        enforce_token_limit(text)
      end

      # Prepare text for each chunk of an ExtractedUnit.
      #
      # If the unit has no chunks, returns a single-element array with the
      # full prepared text. For chunked units, each chunk gets the same
      # context prefix prepended.
      #
      # @param unit [Woods::ExtractedUnit] the unit to prepare
      # @return [Array<String>] array of context-prefixed texts
      def prepare_chunks(unit)
        return [prepare(unit)] unless unit.chunks&.any?

        prefix = build_prefix(unit)
        unit.chunks.map do |chunk|
          text = "#{prefix}\n#{chunk[:content]}"
          enforce_token_limit(text)
        end
      end

      private

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
        dep_names = dependencies.filter_map { |d| d[:target] || d['target'] }.first(10)
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

      # Truncate text to fit within the token budget.
      #
      # Uses the configured `chars_per_token` ratio to estimate both the
      # token count and the safe character cap. Truncation is a last
      # resort — by the time text reaches here the chunker should have
      # already split oversize units into pieces that fit.
      #
      # @param text [String] the text to truncate
      # @return [String] text within token limits
      def enforce_token_limit(text)
        estimated = (text.length / @chars_per_token).ceil
        return text if estimated <= @max_tokens

        max_chars = (@max_tokens * @chars_per_token).floor
        text[0...max_chars]
      end
    end
  end
end
