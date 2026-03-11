# frozen_string_literal: true

module Woods
  # Shared token estimation utility.
  #
  # Uses project convention: (string.length / 4.0).ceil
  # See docs/TOKEN_BENCHMARK.md — conservative floor (~10.6% overestimate).
  module TokenUtils
    module_function

    # Estimate token count for a string.
    #
    # @param text [String] Text to estimate
    # @return [Integer] Estimated token count
    def estimate_tokens(text)
      (text.length / 4.0).ceil
    end
  end
end
