# frozen_string_literal: true

require 'digest'
require 'json'

module CodebaseIndex
  # ExtractedUnit represents a single meaningful unit of code from the codebase.
  #
  # This could be a model, controller, service, component, or framework source.
  # Each unit is self-contained with its source code, metadata, and relationship
  # information. Units are serialized to JSON for consumption by the indexing pipeline.
  #
  # @example Creating a model unit
  #   unit = ExtractedUnit.new(
  #     type: :model,
  #     identifier: "User",
  #     file_path: "app/models/user.rb"
  #   )
  #   unit.source_code = File.read(unit.file_path)
  #   unit.metadata = { associations: [...], callbacks: [...] }
  #   unit.dependencies = [{ type: :service, target: "UserService" }]
  #
  class ExtractedUnit
    attr_accessor :type,           # Symbol: :model, :controller, :service, :component, :job, :rails_source, :gem_source
                  :identifier,     # String: Unique key, e.g., "User", "Users::RegistrationsController#create"
                  :file_path,      # String: Absolute path to source file
                  :namespace,      # String: Module namespace if any
                  :source_code,    # String: The actual code, with concerns inlined for models
                  :metadata,       # Hash: Type-specific structured data
                  :dependencies,   # Array<Hash>: What this unit calls/references
                  :dependents,     # Array<Hash>: What references this unit (populated in second pass)
                  :chunks          # Array<Hash>: Pre-chunked versions if unit is large

    def initialize(type:, identifier:, file_path:)
      @type = type
      @identifier = identifier
      @file_path = file_path
      @metadata = {}
      @dependencies = []
      @dependents = []
      @chunks = []
    end

    # Serialize to hash for JSON output
    #
    # @return [Hash] Complete unit data for indexing pipeline
    def to_h
      {
        type: type,
        identifier: identifier,
        file_path: file_path,
        namespace: namespace,
        source_code: source_code,
        metadata: metadata,
        dependencies: dependencies,
        dependents: dependents,
        chunks: chunks,
        extracted_at: Time.now.iso8601,
        source_hash: Digest::SHA256.hexdigest(source_code || '')
      }
    end

    # Estimate token count for chunking decisions.
    # Ruby code averages ~3.2-3.5 chars per token (vs ~4 for English prose)
    # due to syntax density: symbols (:name), do/end blocks, underscored_names,
    # and operators. Uses 3.5 as a compromise between source code (~3.2) and
    # metadata JSON (~4.0).
    #
    # @return [Integer] Estimated token count
    def estimated_tokens
      @estimated_tokens ||= begin
        source_tokens = source_code ? (source_code.length / 3.5).ceil : 0
        metadata_tokens = metadata.any? ? (metadata.to_json.length / 3.5).ceil : 0
        source_tokens + metadata_tokens
      end
    end

    # Check if unit needs chunking based on size
    #
    # @param threshold [Integer] Token threshold for chunking (default: 1500)
    # @return [Boolean]
    def needs_chunking?(threshold: 1500)
      estimated_tokens > threshold
    end

    # Build semantic chunks for large units
    # Preserves context by including unit header in each chunk
    #
    # @param max_tokens [Integer] Maximum tokens per chunk
    # @return [Array<Hash>] List of chunk hashes
    def build_default_chunks(max_tokens: 1500)
      return [] unless needs_chunking?

      chunks = []
      current_chunk = []
      current_tokens = 0

      # Always include a header with unit context
      header = build_chunk_header
      header_tokens = (header.length / 3.5).ceil

      source_code.lines.each do |line|
        line_tokens = (line.length / 3.5).ceil

        if current_tokens + line_tokens > max_tokens && current_chunk.any?
          content = header + current_chunk.join
          chunks << {
            chunk_index: chunks.size,
            identifier: "#{identifier}#chunk_#{chunks.size}",
            content: content,
            content_hash: Digest::SHA256.hexdigest(content),
            estimated_tokens: current_tokens + header_tokens
          }
          current_chunk = []
          current_tokens = 0
        end

        current_chunk << line
        current_tokens += line_tokens
      end

      # Final chunk
      if current_chunk.any?
        content = header + current_chunk.join
        chunks << {
          chunk_index: chunks.size,
          identifier: "#{identifier}#chunk_#{chunks.size}",
          content: content,
          content_hash: Digest::SHA256.hexdigest(content),
          estimated_tokens: current_tokens + header_tokens
        }
      end

      chunks
    end

    private

    def build_chunk_header
      <<~HEADER
        # Unit: #{identifier} (#{type})
        # File: #{file_path}
        # Namespace: #{namespace || '(root)'}
        # ---
      HEADER
    end
  end
end
