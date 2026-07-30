# frozen_string_literal: true

require 'digest'
require_relative 'provider'

module Woods
  module Embedding
    module Provider
      # Deterministic, dependency-free embedding provider (#178).
      #
      # Embeds text via bag-of-words hashing: each word is hashed to a
      # bucket, contributions are accumulated, and the result is
      # L2-normalized. Texts sharing vocabulary therefore score a higher
      # cosine similarity than unrelated texts, which keeps vector search
      # *mechanically* meaningful — results are ordered, filters apply,
      # budgets are respected.
      #
      # The vectors are **deterministic, NOT semantically meaningful
      # embeddings**. This provider exists so the embed → store → retrieve
      # pipeline can run in CI, sandboxes, smoke tests, and offline hosts
      # with no network endpoint; never rely on it for production retrieval
      # quality.
      #
      # Unlike {OpenAI} and {Ollama} it performs no I/O, so it never raises
      # {RequestError} — the resilience stack ({Woods::Resilience::RetryableProvider})
      # wraps it harmlessly as a no-op. It also accepts nil/empty input
      # (yielding a zero vector) where the network providers raise
      # +ArgumentError+ to pre-empt a provider-side 400.
      #
      # Wire it up with +config.embedding_provider = :fake+ — see
      # {Woods::Builder#build_embedding_provider}.
      #
      # @example Offline CI configuration
      #   Woods.configure do |config|
      #     config.embedding_provider = :fake
      #     config.embedding_options = { dims: 128 } # optional
      #   end
      class Fake
        include Interface

        # Default output dimensionality. Small on purpose — fake vectors
        # carry no semantic signal worth paying more dimensions for.
        DEFAULT_DIMS = 128

        # Default {#model_name}. Deliberately unmistakable so a
        # fake-embedded index is never confused with a real one in
        # woods.json or woods_status output.
        DEFAULT_MODEL_NAME = 'fake-embedding-test'

        # @return [Array<Array<String>>] record of all embed/embed_batch
        #   calls, in order — one entry per call, each the array of texts
        #   embedded. For test inspection; grows unboundedly, which is
        #   acceptable for the smoke/CI runs this provider is meant for.
        attr_reader :calls

        # @param dims [Integer] dimensionality of output vectors (default 128)
        # @param model [String] name reported by {#model_name}. Accepted so
        #   the MCP boot path can restore a provider from woods.json, which
        #   records a model name for every provider class.
        # @raise [ArgumentError] if dims is not a positive integer
        def initialize(dims: DEFAULT_DIMS, model: DEFAULT_MODEL_NAME)
          @dims = Integer(dims)
          raise ArgumentError, "dims must be positive, got #{dims.inspect}" unless @dims.positive?

          @model = model.to_s
          @calls = []
        end

        # Embed a single text into a deterministic vector.
        #
        # @param text [String]
        # @return [Array<Float>]
        def embed(text)
          @calls << [text]
          text_to_vector(text)
        end

        # Embed a batch of texts.
        #
        # @param texts [Array<String>]
        # @return [Array<Array<Float>>]
        def embed_batch(texts)
          @calls << texts
          texts.map { |t| text_to_vector(t) }
        end

        # @return [Integer] configured output dimensionality
        def dimensions
          @dims
        end

        # @return [String] the configured model name (default
        #   {DEFAULT_MODEL_NAME})
        def model_name
          @model
        end

        # No input budget — signals the indexer to skip auto-chunking.
        # Tests that need chunking behaviour should subclass and override.
        #
        # @return [nil]
        def max_input_tokens
          nil
        end

        private

        # Convert text to a normalized vector using bag-of-words hashing.
        #
        # Each word is hashed to a bucket index and its contribution is accumulated.
        # The resulting vector is L2-normalized so cosine similarity works correctly.
        #
        # @param text [String]
        # @return [Array<Float>]
        def text_to_vector(text)
          vec = Array.new(@dims, 0.0)
          words = text.to_s.downcase.scan(/[a-z_][a-z0-9_]*/i)
          words.each do |word|
            bucket = Digest::SHA256.hexdigest(word).to_i(16) % @dims
            vec[bucket] += 1.0
          end
          normalize(vec)
        end

        # L2-normalize a vector. Returns zero vector if magnitude is zero.
        #
        # @param vec [Array<Float>]
        # @return [Array<Float>]
        def normalize(vec)
          magnitude = Math.sqrt(vec.sum { |v| v**2 })
          return vec if magnitude.zero?

          vec.map { |v| v / magnitude }
        end
      end
    end
  end
end
