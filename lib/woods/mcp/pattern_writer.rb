# frozen_string_literal: true

require 'fileutils'
require 'json'
require_relative '../extracted_unit'
require_relative '../filename_utils'

module Woods
  module MCP
    # Writes agent-authored patterns to disk as ExtractedUnit JSON files.
    #
    # Patterns are stored in a `patterns/` subdirectory of the index,
    # alongside extracted units but clearly distinguished by `type: :pattern`
    # and `metadata.authored_by: "agent"`.
    #
    # Supports upsert semantics — writing the same identifier again overwrites
    # the previous version on disk and in the vector store. A `supersedes`
    # metadata field tracks correction lineage.
    #
    # @example
    #   writer = PatternWriter.new(index_dir: "/path/to/woods")
    #   writer.write(identifier: "order-payment-flow", content: "The Order→Payment flow requires...")
    #
    class PatternWriter
      extend FilenameUtils

      VALID_IDENTIFIER = /\A[a-zA-Z0-9_:.\-\/]+\z/
      MAX_IDENTIFIER_LENGTH = 256
      MAX_CONTENT_LENGTH = 50_000

      # @param index_dir [String] Path to extraction output directory
      def initialize(index_dir:)
        @index_dir = index_dir
        @patterns_dir = File.join(index_dir, 'patterns')
      end

      # Write a pattern to disk as ExtractedUnit JSON.
      #
      # @param identifier [String] Unique name for this pattern
      # @param content [String] The pattern description/insight
      # @param metadata [Hash] Additional metadata (tags, etc.)
      # @param supersedes [String, nil] Identifier of the pattern this corrects
      # @return [Woods::ExtractedUnit] The written unit
      # @raise [ArgumentError] if identifier, content, or metadata fails validation
      def write(identifier:, content:, metadata: {}, supersedes: nil)
        validate_identifier!(identifier)
        validate_content!(content)
        validate_metadata!(metadata)

        metadata = normalize_metadata(metadata)
        validate_tags!(metadata['tags']) if metadata.key?('tags')

        unit = build_unit(identifier: identifier, content: content, metadata: metadata, supersedes: supersedes)

        FileUtils.mkdir_p(@patterns_dir)
        filename = self.class.collision_safe_filename(identifier)
        File.write(File.join(@patterns_dir, filename), JSON.pretty_generate(unit.to_h))

        update_index(identifier, unit)

        unit
      end

      # Delete a pattern from disk.
      #
      # @param identifier [String] Pattern identifier to remove
      # @return [Boolean] true if found and deleted, false otherwise
      def delete(identifier)
        filename = self.class.collision_safe_filename(identifier)
        path = File.join(@patterns_dir, filename)
        return false unless File.exist?(path)

        File.delete(path)
        remove_from_index(identifier)
        true
      end

      # List all patterns from _index.json.
      #
      # @param tag [String, nil] Optional tag to filter by
      # @return [Array<Hash>] Pattern index entries
      def list(tag: nil)
        index_path = File.join(@patterns_dir, '_index.json')
        return [] unless File.exist?(index_path)

        entries = JSON.parse(File.read(index_path))
        return entries unless tag

        entries.select do |entry|
          (entry['tags'] || []).include?(tag)
        end
      end

      # Embed a pattern unit into the vector store.
      #
      # @param unit [Woods::ExtractedUnit] The pattern unit to embed
      # @param provider [#embed_batch] Embedding provider
      # @param vector_store [#store] Vector store backend
      # @param text_preparer [Woods::Embedding::TextPreparer] Text preparer
      # @return [void]
      def embed(unit, provider:, vector_store:, text_preparer:)
        text = text_preparer.prepare(unit)
        vectors = provider.embed_batch([text])
        vector_store.store(
          unit.identifier,
          vectors[0],
          { type: 'pattern', identifier: unit.identifier, file_path: unit.file_path }
        )
      end

      private

      def build_unit(identifier:, content:, metadata:, supersedes:)
        unit = Woods::ExtractedUnit.new(
          type: :pattern,
          identifier: identifier,
          file_path: "agent://patterns/#{identifier}"
        )
        unit.source_code = content
        unit.metadata = metadata.merge(
          'authored_by' => 'agent',
          'supersedes' => supersedes
        ).compact
        unit
      end

      def normalize_metadata(metadata)
        metadata.transform_keys(&:to_s)
      end

      def validate_identifier!(identifier)
        raise ArgumentError, 'Identifier must be a non-empty string' if identifier.nil? || identifier.empty?
        raise ArgumentError, "Identifier exceeds #{MAX_IDENTIFIER_LENGTH} characters" if identifier.length > MAX_IDENTIFIER_LENGTH
        raise ArgumentError, "Identifier contains invalid characters: #{identifier}" unless identifier.match?(VALID_IDENTIFIER)
      end

      def validate_content!(content)
        raise ArgumentError, 'Content must be a non-empty string' if content.nil? || content.empty?
        raise ArgumentError, "Content exceeds #{MAX_CONTENT_LENGTH} characters" if content.length > MAX_CONTENT_LENGTH
      end

      def validate_metadata!(metadata)
        raise ArgumentError, 'Metadata must be a Hash' unless metadata.is_a?(Hash)
      end

      def validate_tags!(tags)
        return unless tags

        raise ArgumentError, 'Tags must be an array' unless tags.is_a?(Array)

        tags.each do |tag|
          raise ArgumentError, "Each tag must be a string, got: #{tag.class}" unless tag.is_a?(String)
          raise ArgumentError, "Tag contains invalid characters: #{tag}" unless tag.match?(/\A[a-zA-Z0-9_ -]+\z/)
        end
      end

      def update_index(identifier, unit)
        index_path = File.join(@patterns_dir, '_index.json')
        new_content = atomic_index_update(index_path) do |existing|
          existing.reject! { |e| e['identifier'] == identifier }
          existing << {
            'identifier' => identifier,
            'file_path' => unit.file_path,
            'estimated_tokens' => unit.estimated_tokens,
            'tags' => unit.metadata['tags'] || []
          }
          existing
        end
        File.write(index_path, new_content)
      end

      def remove_from_index(identifier)
        index_path = File.join(@patterns_dir, '_index.json')
        return unless File.exist?(index_path)

        new_content = atomic_index_update(index_path) do |existing|
          existing.reject! { |e| e['identifier'] == identifier }
          existing
        end
        File.write(index_path, new_content)
      end

      # Read _index.json under an exclusive lock, yield entries for modification,
      # and return the new JSON string. The caller writes the result outside the lock
      # to minimize lock hold time.
      def atomic_index_update(index_path)
        entries = File.open(index_path, File::RDWR | File::CREAT, 0o644) do |f|
          f.flock(File::LOCK_EX)
          f.size.positive? ? JSON.parse(f.read) : []
        end
        updated = yield(entries)
        JSON.pretty_generate(updated)
      end
    end
  end
end
