# frozen_string_literal: true

module CodebaseIndex
  module CostModel
    # Calculates vector storage requirements based on embedding dimensions
    # and chunk count.
    #
    # Bytes per vector = dimensions × 4 (float32), with a 1.3× metadata
    # overhead factor applied per BACKEND_MATRIX.md.
    #
    # @example
    #   calc = StorageCost.new(dimensions: 1536)
    #   calc.storage_bytes(chunks: 1250) # => 9_984_000
    #   calc.storage_mb(chunks: 1250)    # => 9.52
    #
    class StorageCost
      # Bytes per float32 value.
      BYTES_PER_FLOAT = 4

      # Metadata overhead multiplier (JSONB payload, indexes, etc.).
      METADATA_OVERHEAD = 1.3

      # @param dimensions [Integer] Embedding vector dimensions
      def initialize(dimensions:)
        @dimensions = dimensions
      end

      # Bytes per vector including metadata overhead.
      #
      # @return [Integer]
      def bytes_per_vector
        @bytes_per_vector ||= (@dimensions * BYTES_PER_FLOAT * METADATA_OVERHEAD).ceil
      end

      # Total storage in bytes for a given number of chunks.
      #
      # @param chunks [Integer] Total number of chunks (units × chunk_multiplier)
      # @return [Integer]
      def storage_bytes(chunks:)
        chunks * bytes_per_vector
      end

      # Total storage in megabytes for a given number of chunks.
      #
      # @param chunks [Integer] Total number of chunks
      # @return [Float] Storage in MB, rounded to 2 decimal places
      def storage_mb(chunks:)
        (storage_bytes(chunks: chunks).to_f / (1024 * 1024)).round(2)
      end
    end
  end
end
