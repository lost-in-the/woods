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
        dir = Woods::MCP::IndexReader::TYPE_TO_DIR[type]
        return nil unless dir
        return nil unless reader.list_units(type: type).any? { |entry| entry['identifier'] == identifier }

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

      private_class_method :filename_for
    end
  end
end
