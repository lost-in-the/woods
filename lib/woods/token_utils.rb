# frozen_string_literal: true

module Woods
  # Shared token estimation utility — the single source of truth for the
  # chars-per-token ratio used across cost estimation, context assembly,
  # and embedding budgeting.
  #
  # Ratios:
  # - `:openai` / default — 4.0 chars/token. Benchmarked against tiktoken
  #   (cl100k_base) on 19 Ruby source files (mean 4.41 chars/token). We use
  #   4.0 as a conservative floor (~10.6 % overestimate) so truncation never
  #   hands the model more tokens than it budgeted for. See
  #   `docs/TOKEN_BENCHMARK.md`.
  # - `:ollama` — 1.5 chars/token. Matches the BERT WordPiece tokenizers
  #   used by nomic-embed-text and mxbai-embed-large. See
  #   `docs/EMBEDDING_MODELS.md` and `Woods::Builder#chars_per_token_for`.
  #
  # Callers should prefer {.chars_per_token_for} over hardcoding a divisor
  # so future tokenizer changes propagate in one place instead of drifting
  # between {ContextAssembler}, {Builder}, and cost-model components.
  module TokenUtils
    CHARS_PER_TOKEN_BY_PROVIDER = {
      openai: 4.0,
      ollama: 1.5
    }.freeze

    DEFAULT_CHARS_PER_TOKEN = CHARS_PER_TOKEN_BY_PROVIDER[:openai]

    module_function

    # Chars-per-token ratio for the given embedding provider.
    #
    # @param provider [Symbol, String, nil] Provider identifier. Unknown or
    #   nil providers fall back to {DEFAULT_CHARS_PER_TOKEN}.
    # @return [Float]
    def chars_per_token_for(provider)
      CHARS_PER_TOKEN_BY_PROVIDER.fetch(provider&.to_sym, DEFAULT_CHARS_PER_TOKEN)
    end

    # Estimate token count for a string using the default (OpenAI) ratio.
    # Use {.estimate_tokens_for} when a specific provider is in play.
    #
    # @param text [String] Text to estimate
    # @return [Integer] Estimated token count
    def estimate_tokens(text)
      estimate_tokens_for(text, provider: nil)
    end

    # Estimate token count for a string using the provider's native ratio.
    #
    # @param text [String] Text to estimate
    # @param provider [Symbol, String, nil] `:openai`, `:ollama`, or nil.
    # @return [Integer] Estimated token count
    def estimate_tokens_for(text, provider:)
      (text.length / chars_per_token_for(provider)).ceil
    end
  end
end
