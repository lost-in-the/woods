# frozen_string_literal: true

require 'set'

module Woods
  module Embedding
    # Exact or estimated token counts for embedding inputs.
    #
    # When the optional `tokenizers` gem (ankane) is installed, loads the
    # `bert-base-uncased` WordPiece tokenizer that nomic-embed-text is
    # built on and returns exact token counts. Otherwise falls back to a
    # conservative chars/token ratio and warns once.
    #
    # Exact counting is strictly preferred for the Ollama path — Ollama
    # v0.13.5+ stopped honouring the `truncate: true` flag on
    # `/api/embed` (see ollama/ollama#14186), so chunks that exceed
    # `num_ctx` return a 400 instead of being truncated. Client-side
    # sizing is the only reliable option until the regression is fixed
    # upstream, and chars/token ratios vary too widely across Rails
    # internals to cover every case with a fixed number.
    #
    # @example
    #   counter = Woods::Embedding::TokenCounter.new
    #   counter.count("ActionController::Metal::ConditionalGet")  # => 13
    class TokenCounter
      # HuggingFace tokenizer id shared by every nomic-embed-text variant.
      BERT_MODEL = 'bert-base-uncased'

      # Conservative floor for when the tokenizer gem isn't installed.
      # Lower than any ratio we've observed failing in the testbed
      # against dense Rails source. Still approximate — install
      # `tokenizers` for exact counts.
      CONSERVATIVE_CHARS_PER_TOKEN = 1.2

      # @param chars_per_token [Float] fallback ratio when the tokenizer
      #   is unavailable
      # @param tokenizer_id [String] HuggingFace model id passed to
      #   `Tokenizers.from_pretrained`
      def initialize(chars_per_token: CONSERVATIVE_CHARS_PER_TOKEN, tokenizer_id: BERT_MODEL)
        @chars_per_token = chars_per_token
        @tokenizer_id = tokenizer_id
        @load_attempted = false
        @load_mutex = Mutex.new
      end

      # @return [Float] fallback chars-per-token ratio
      attr_reader :chars_per_token

      # Exact token count when the tokenizer is loaded, chars/token
      # estimate otherwise.
      #
      # @param text [String, nil]
      # @return [Integer]
      def count(text)
        return 0 if text.nil? || text.empty?

        tok = tokenizer
        tok ? tok.encode(text).ids.length : estimate(text)
      end

      private

      def estimate(text)
        (text.length / @chars_per_token).ceil
      end

      # Lazy-load the tokenizer under a mutex so concurrent first-calls
      # don't each trigger a separate download. After the first attempt
      # (successful or not) we memoize the result and skip the load path.
      def tokenizer
        @load_mutex.synchronize do
          return @tokenizer if @load_attempted

          @load_attempted = true
          @tokenizer = try_load
        end
      end

      def try_load
        require 'tokenizers'
        Tokenizers.from_pretrained(@tokenizer_id)
      rescue LoadError
        warn_once(
          'Exact token counting disabled: `tokenizers` gem not installed. ' \
          "Falling back to #{@chars_per_token} chars/token estimation. " \
          "Add `gem 'tokenizers', '~> 0.5'` to your Gemfile for exact sizing on Ollama."
        )
        nil
      rescue StandardError => e
        warn_once(
          "Could not load tokenizer #{@tokenizer_id.inspect} " \
          "(#{e.class}: #{e.message}). Falling back to chars/token estimate."
        )
        nil
      end

      # Per-process dedup so multiple TokenCounter instances (one per
      # retriever build, plus one per chunker, plus tests) don't each
      # spam the same fallback warning. The mutex keeps the dedup set
      # consistent under the same concurrent-first-call pattern that
      # the per-instance load mutex protects against.
      @warned_messages = Set.new
      @warned_mutex = Mutex.new

      class << self
        attr_reader :warned_messages, :warned_mutex

        # Reset the per-process warning dedup. For tests only — production
        # callers should never need to clear it.
        def reset_warned!
          @warned_mutex.synchronize { @warned_messages.clear }
        end
      end

      def warn_once(message)
        full = "[woods] #{message}"
        self.class.warned_mutex.synchronize do
          return if self.class.warned_messages.include?(full)

          self.class.warned_messages << full
        end
        Kernel.warn(full)
      end
    end
  end
end
