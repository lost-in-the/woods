# frozen_string_literal: true

module Woods
  # Shared building blocks for the export formatters (Unblocked DocumentBuilder,
  # Obsidian NoteBuilder).
  module Export
    # Format-agnostic extraction of facts from a unit's metadata.
    #
    # Both the Unblocked and Obsidian exporters need the same *facts* about a
    # unit — its associations grouped by macro, its schema highlights — but
    # render them differently (plain text + GitHub URIs vs. wikilinks +
    # frontmatter). This value object owns the one definition of "what a unit's
    # metadata says"; each exporter is a thin formatter over it. The returned
    # structures are deliberately raw (no truncation, no ordering imposed beyond
    # the source array): formatting decisions — sort order, top-N caps — belong
    # to each formatter so neither exporter's output is constrained by the other.
    class UnitFacts
      # @param unit [Hash] parsed unit JSON
      def initialize(unit)
        @meta = (unit && unit['metadata']) || {}
      end

      # Associations grouped by macro, each as a structured entry. Group keys are
      # whatever macros are present (insertion order from the source array); the
      # formatter picks the display order.
      #
      # @return [Hash{String=>Array<Hash>}] macro => [{ target:, dependent: }]
      def associations_by_type
        associations.group_by { |assoc| assoc['type'] }.transform_values do |items|
          items.map { |a| { target: a['target'] || a['name'], dependent: a.dig('options', 'dependent') } }
        end
      end

      # @return [Integer] total association count across all macros
      def association_count
        associations.size
      end

      # @return [Hash] { enums:, scopes:, concerns:, callbacks: } — raw, untruncated
      def schema_highlights
        { enums: enums, scopes: scopes, concerns: concerns, callbacks: callbacks }
      end

      def enums
        @meta['enums'].is_a?(Hash) ? @meta['enums'] : {}
      end

      def scopes
        @meta['scopes'].is_a?(Array) ? @meta['scopes'].filter_map { |s| s['name'] } : []
      end

      def concerns
        @meta['inlined_concerns'].is_a?(Array) ? @meta['inlined_concerns'] : []
      end

      def callbacks
        return [] unless @meta['callbacks'].is_a?(Array)

        @meta['callbacks'].map { |cb| { type: cb['type'], filter: cb['filter'] } }
      end

      private

      def associations
        @meta['associations'].is_a?(Array) ? @meta['associations'] : []
      end
    end
  end
end
