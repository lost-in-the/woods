# frozen_string_literal: true

require 'digest'
require 'json'

module Woods
  class PublishedIndex
    # Reads one type's unit file directly from a pinned payload, bypassing
    # {Woods::MCP::IndexReader#find_unit}'s identifier-only map, which lets a
    # later `TYPE_DIRS` entry silently overwrite an earlier one when two
    # types share an identifier.
    #
    # Split out of {PublishedIndex} for the same reason as {EdgeShaper}: a
    # pure function of the payload directory and the reader's own per-type
    # index, with no need to touch the retention lock.
    module TypedUnitReader
      # @param payload_dir [Pathname] the pinned generation's payload directory
      # @param reader [Woods::MCP::IndexReader]
      # @param identifier [String]
      # @param type [String] singular type name
      # @return [Hash, nil] string-keyed unit, or nil when this type has no
      #   such identifier
      def self.call(payload_dir, reader, identifier, type)
        dir = directory_for(type)
        return nil unless dir

        family = Woods::MCP::IndexReader::DIR_TO_TYPE.fetch(dir)
        return nil unless reader.list_units(type: family).any? { |entry| entry['identifier'] == identifier }

        unit = read_unit(payload_dir, dir, identifier)
        unit if unit && (unit['type'] == type || type == family)
      end

      # Resolve actual published types as well as historical directory-family aliases.
      #
      # @param type [String]
      # @return [String, nil]
      def self.directory_for(type)
        Woods::MCP::IndexReader::TYPE_TO_DIR[type] ||
          Woods::MCP::IndexReader::UNIT_TYPES_BY_DIR.find { |_, types| types.include?(type) }&.first
      end

      # Preserve subtype identity in an index entry from a shared type directory.
      #
      # @param payload_dir [Pathname]
      # @param entry [Hash] published index entry
      # @param dir [String] type directory
      # @param requested_type [String, nil] actual type or family alias
      # @return [Hash, nil] entry with actual type, or nil when filtered out
      def self.entry(payload_dir, entry, dir, requested_type)
        family = Woods::MCP::IndexReader::DIR_TO_TYPE.fetch(dir)
        actual_type = if Woods::MCP::IndexReader::UNIT_TYPES_BY_DIR.fetch(dir).size > 1
                        read_unit(payload_dir, dir, entry['identifier'])&.fetch('type')
                      else
                        family
                      end
        return unless actual_type
        return if requested_type && requested_type != family && requested_type != actual_type

        entry.merge('type' => actual_type)
      end

      # Read a unit whose directory-index membership has already been established.
      def self.read_unit(payload_dir, dir, identifier)
        path = payload_dir.join(dir, filename_for(identifier))
        return nil unless path.file?

        JSON.parse(path.binread.force_encoding(Encoding::UTF_8))
      end

      # The on-disk filename for a unit, matching
      # `Woods::MCP::IndexReader#build_identifier_map`'s naming exactly.
      #
      # @param identifier [String]
      # @return [String]
      def self.filename_for(identifier)
        base = identifier.gsub('::', '__').gsub(/[^a-zA-Z0-9_-]/, '_')
        digest = Digest::SHA256.hexdigest(identifier)[0, 8]
        "#{base}_#{digest}.json"
      end

      private_class_method :filename_for, :read_unit
    end
  end
end
