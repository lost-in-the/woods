# frozen_string_literal: true

module Woods
  class PublishedIndex
    # Maps the type names {PublishedIndex#units} accepts onto the reader's
    # type directories and labels index entries with each unit's actual type.
    #
    # Unit bodies are read through {Woods::MCP::IndexReader#find_unit} with
    # +type:+, the one guarded typed-read path (F7); nothing here opens a
    # payload file itself.
    #
    # Split out of {PublishedIndex} for the same reason as {EdgeShaper}: a
    # pure function of the reader and its per-type index, with no need to
    # touch the retention lock.
    module TypedUnitReader
      # Resolve actual published types as well as historical directory-family aliases.
      #
      # @param type [String]
      # @return [String, nil]
      def self.directory_for(type)
        Woods::MCP::IndexReader::TYPE_TO_DIR[type] ||
          Woods::MCP::IndexReader::UNIT_TYPES_BY_DIR.find { |_, types| types.include?(type) }&.first
      end

      # Read one unit through the reader's guarded typed path. A directory
      # family (`graphql`; `rails_source`, which the MCP `lookup` tool treats
      # as the unit type) selects any member, as {PublishedIndex} documents.
      #
      # @param reader [Woods::MCP::IndexReader]
      # @param identifier [String]
      # @param type [String] actual unit type or directory-family alias
      # @return [Hash, nil]
      # @raise [IOError] when the typed read fails the reader's guards
      def self.call(reader, identifier, type)
        if reader.unit_types_for(type).size > 1
          reader.find_family_unit(identifier, type)
        else
          reader.find_unit(identifier, type: type)
        end
      end

      # Preserve subtype identity in an index entry from a shared type directory.
      # An entry that names a type of its directory (indexes written since
      # Woods records it) is labelled from the index; an older entry, or one
      # naming a type the directory cannot hold, is labelled by reading its
      # unit through the guarded typed path.
      #
      # @param reader [Woods::MCP::IndexReader]
      # @param entry [Hash] published index entry
      # @param dir [String] type directory
      # @param requested_type [String, nil] actual type or family alias
      # @return [Hash, nil] entry with actual type, or nil when filtered out
      # @raise [IOError] when a multi-type directory's unit fails the reader's guards
      def self.entry(reader, entry, dir, requested_type)
        family = Woods::MCP::IndexReader::DIR_TO_TYPE.fetch(dir)
        actual_type = entry_type(reader, entry, dir, family)
        return unless actual_type
        return if requested_type && requested_type != family && requested_type != actual_type

        entry.merge('type' => actual_type)
      end

      # @return [String, nil] the entry's actual type
      def self.entry_type(reader, entry, dir, family)
        types = Woods::MCP::IndexReader::UNIT_TYPES_BY_DIR.fetch(dir)
        return family if types.one?
        return entry['type'] if types.include?(entry['type'])

        call(reader, entry['identifier'], family)&.fetch('type')
      end
      private_class_method :entry_type
    end
  end
end
