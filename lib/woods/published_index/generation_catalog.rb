# frozen_string_literal: true

module Woods
  class PublishedIndex
    # Resolves `generation.json` and enumerates published `payloads/gen-N`
    # directories.
    #
    # Split out of {PublishedIndex} because this is pure pointer and
    # directory inspection: it never touches an open reader or its retention
    # lock, and keeping it separate is what lets {PublishedIndex} itself stay
    # under `Metrics/ClassLength` without an exclude entry.
    module GenerationCatalog
      # The published generation pointer, distinguishing "no pointer file"
      # (a flat index, where {Woods::Generation::UNPUBLISHED} is the honest
      # answer) from "a pointer file that will not parse" (a corrupt install,
      # which {Woods::Generation#current} silently maps to that same
      # UNPUBLISHED sentinel). Only this method's caller has already checked
      # which one it is, so only here can the two be told apart.
      #
      # @param root [Pathname]
      # @return [Woods::Generation::Marker]
      # @raise [PublishedIndex::CorruptPointerError] when the file exists but will not parse
      def self.pointer(root)
        generation = Woods::Generation.new(output_dir: root)
        return Woods::Generation::UNPUBLISHED unless File.exist?(generation.path)

        marker = generation.current
        return marker unless marker.equal?(Woods::Generation::UNPUBLISHED)

        raise PublishedIndex::CorruptPointerError, "Unreadable generation pointer: #{generation.path}"
      end

      # Published generation numbers, ascending. See
      # {PublishedIndex.available_generations} for what "published" means.
      #
      # @param root [Pathname]
      # @return [Array<Integer>]
      # @raise [PublishedIndex::CorruptPointerError] when `generation.json` exists but will not parse
      def self.available(root)
        marker = pointer(root)
        return [] if marker.number.zero?

        payloads = Woods::PayloadStore.new(root)
        return [] unless payloads.root.directory?

        payloads.root.children.filter_map { |child| published_number(child, marker.number) }.sort
      end

      # A directory's generation number, when it qualifies as published:
      # named `gen-<N>` for N at or below +pointer+, holding a
      # `manifest.json`.
      #
      # @param child [Pathname]
      # @param pointer [Integer] the currently published generation number
      # @return [Integer, nil]
      def self.published_number(child, pointer)
        return nil unless child.directory?

        match = child.basename.to_s.match(/\Agen-(\d+)\z/)
        return nil unless match

        number = match[1].to_i
        return nil if number > pointer
        return nil unless child.join('manifest.json').file?

        number
      end

      private_class_method :published_number
    end
  end
end
