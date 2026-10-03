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
      # answer) from "a pointer file that will not parse or names no valid
      # generation" (a corrupt install). {Woods::Generation#current!} is the
      # strict reader that already draws that line for every long-lived
      # reader; this only translates its {Woods::Generation::InvalidMarker}
      # into the {PublishedIndex} error its callers rescue (F7).
      #
      # @param root [Pathname]
      # @return [Woods::Generation::Marker]
      # @raise [PublishedIndex::CorruptPointerError] when the file exists but
      #   will not parse or does not describe a generation
      def self.pointer(root)
        generation = Woods::Generation.new(output_dir: root)
        generation.current!
      rescue Woods::Generation::InvalidMarker => e
        raise PublishedIndex::CorruptPointerError, "Unreadable generation pointer: #{generation.path} (#{e.message})"
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
