# frozen_string_literal: true

require 'digest'
require 'codebase_index/embedding/provider'

module CodebaseIndex
  module Embedding
    module Provider
      # Deterministic embedding provider for testing.
      #
      # Uses a bag-of-words approach with hash-based projection so that
      # texts sharing words produce vectors with higher cosine similarity.
      # This makes vector search tests meaningful without requiring a real model.
      class Fake
        include Interface

        # @param dims [Integer] dimensionality of output vectors (default 128)
        def initialize(dims: 128)
          @dims = dims
          @calls = []
        end

        # @return [Array<Array<String>>] record of all embed/embed_batch calls
        attr_reader :calls

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

        # @return [Integer]
        def dimensions
          @dims
        end

        # @return [String]
        def model_name
          'fake-embedding-test'
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
          words = text.downcase.scan(/[a-z_][a-z0-9_]*/i)
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
