# frozen_string_literal: true

require 'digest'

module CodebaseIndex
  module Chunking
    # A single semantic chunk extracted from an ExtractedUnit.
    #
    # Chunks represent meaningful subsections of a code unit — associations,
    # callbacks, validations, individual actions, etc. Each chunk is independently
    # embeddable and retrievable, with a back-reference to its parent unit.
    #
    # @example
    #   chunk = Chunk.new(
    #     content: "has_many :posts\nhas_many :comments",
    #     chunk_type: :associations,
    #     parent_identifier: "User",
    #     parent_type: :model
    #   )
    #   chunk.token_count  # => 20
    #   chunk.identifier   # => "User#associations"
    #
    class Chunk
      attr_reader :content, :chunk_type, :parent_identifier, :parent_type, :metadata

      # @param content [String] The chunk's source code or text
      # @param chunk_type [Symbol] Semantic type (:summary, :associations, :callbacks, etc.)
      # @param parent_identifier [String] Identifier of the parent ExtractedUnit
      # @param parent_type [Symbol] Type of the parent unit (:model, :controller, etc.)
      # @param metadata [Hash] Optional chunk-specific metadata
      def initialize(content:, chunk_type:, parent_identifier:, parent_type:, metadata: {})
        @content = content
        @chunk_type = chunk_type
        @parent_identifier = parent_identifier
        @parent_type = parent_type
        @metadata = metadata
      end

      # Estimated token count using project convention.
      #
      # @return [Integer]
      def token_count
        @token_count ||= (content.length / 4.0).ceil
      end

      # SHA256 hash of content for change detection.
      #
      # @return [String]
      def content_hash
        @content_hash ||= Digest::SHA256.hexdigest(content)
      end

      # Unique identifier combining parent and chunk type.
      #
      # @return [String]
      def identifier
        "#{parent_identifier}##{chunk_type}"
      end

      # Whether the chunk has no meaningful content.
      #
      # @return [Boolean]
      def empty?
        content.nil? || content.strip.empty?
      end

      # Serialize to hash for JSON output.
      #
      # @return [Hash]
      def to_h
        {
          content: content,
          chunk_type: chunk_type,
          parent_identifier: parent_identifier,
          parent_type: parent_type,
          identifier: identifier,
          token_count: token_count,
          content_hash: content_hash,
          metadata: metadata
        }
      end
    end
  end
end
