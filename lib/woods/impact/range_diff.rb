# frozen_string_literal: true

require_relative 'value'
require_relative 'line_diff'

module Woods
  module Impact
    # Pure typed payload comparison. Hash facets are separate from interpretation.
    class RangeDiff
      FIELDS = { 'source' => 'source_code', 'metadata' => 'metadata', 'dependencies' => 'dependencies' }.freeze
      SOURCE_CATEGORIES = {
        'view_template' => 'template', 'test_mapping' => 'tests', 'test_support' => 'tests',
        'route' => 'routing', 'route_file' => 'routing', 'model' => 'behaviour', 'controller' => 'behaviour',
        'service' => 'behaviour', 'job' => 'behaviour', 'mailer' => 'behaviour', 'concern' => 'behaviour',
        'ruby_method' => 'behaviour'
      }.freeze
      CATEGORY_KEYS = {
        'schema' => %w[columns indexes foreign_keys primary_key associations table_name database],
        'behaviour' => %w[callbacks filters actions methods instance_methods class_methods],
        'routing' => %w[routes verb path controller action],
        'template' => %w[renders partials_rendered instance_variables helpers_called],
        'tests' => %w[tested_units test_files]
      }.freeze

      # Changed line ranges kept for one unit (#802).
      SOURCE_HUNKS_PER_UNIT = 200

      # @param before [Hash] typed units
      # @param after [Hash] typed units
      # @param max_source_hunks [Integer] changed line ranges kept across the report
      def initialize(before, after, max_source_hunks: 10_000)
        @before = before
        @after = after
        @source_budget = max_source_hunks
      end

      # @return [Array<Hash>] changes sorted by identifier and actual type
      def changes
        (@before.keys | @after.keys).sort.filter_map do |identity|
          before = @before[identity]
          after = @after[identity]
          facets = FIELDS.filter_map { |facet, field| facet unless same_field?(before, after, field) }
          next if before && after && facets.empty?

          change(identity, before, after, facets)
        end
      end

      private

      # A facet is unchanged when both endpoints carry it with the same
      # canonical JSON. Compared structurally: most units of a range are
      # unchanged, and serialising each one to compare it dominated a large
      # large range.
      def same_field?(before, after, field)
        before && after && Value.same?(before.fetch(field), after.fetch(field))
      end

      def change(identity, before, after, facets)
        { 'identifier' => identity[0], 'type' => identity[1], 'status' => status(before, after),
          'facets' => facets, 'categories' => categories(before, after, facets),
          'metadata_keys' => changed_metadata_keys(before, after),
          'diff_stats' => { 'source_before' => source_size(before), 'source_after' => source_size(after) } }
          .merge(source_changes(before, after, facets)).merge(column_changes(before, after))
      end

      # Which columns moved (#821), by name, when a modified unit's `columns`
      # metadata did and both endpoints publish named columns.
      def column_changes(before, after)
        old = named_columns(before)
        new = named_columns(after)
        return {} unless old && new && !Value.same?(old, new)

        modified = (old.keys & new.keys).reject { |name| Value.same?(old[name], new[name]) }
        { 'column_changes' => { 'added' => (new.keys - old.keys).sort, 'removed' => (old.keys - new.keys).sort,
                                'modified' => modified.sort } }
      end

      def named_columns(unit)
        columns = unit && unit.fetch('metadata')['columns']
        return nil unless columns.is_a?(Array) && columns.all? { |column| named?(column) }

        columns.to_h { |column| [column['name'], column] }
      end

      def named?(column)
        column.is_a?(Hash) && column['name'].is_a?(String)
      end

      # Where a modified unit's source moved (#802): changed line ranges in
      # each endpoint's annotated `source_code`, bounded per unit and across
      # the report; a budget spent says `truncated`.
      def source_changes(before, after, facets)
        return {} unless before && after && facets.include?('source')

        changes = LineDiff.new(before['source_code'], after['source_code'])
                          .ranges(max_hunks: [SOURCE_HUNKS_PER_UNIT, @source_budget].min)
        @source_budget -= changes['hunks'].size
        { 'source_changes' => changes }
      end

      def status(before, after)
        return 'added' unless before
        return 'removed' unless after

        'modified'
      end

      def changed_metadata_keys(before, after)
        old = before ? before.fetch('metadata') : {}
        current = after ? after.fetch('metadata') : {}
        (old.keys | current.keys).sort.reject do |key|
          old.key?(key) == current.key?(key) && Value.same?(old[key], current[key])
        end
      end

      def categories(before, after, facets)
        keys = changed_metadata_keys(before, after)
        result = CATEGORY_KEYS.filter_map { |category, fields| category if (fields & keys).any? }
        result << 'edges' if dependencies(before) != dependencies(after)
        result << SOURCE_CATEGORIES[(after || before).fetch('type')] if facets.include?('source')
        result.compact.uniq.sort
      end

      def dependencies(unit)
        unit ? unit.fetch('dependencies') : []
      end

      def source_size(unit)
        source = unit && unit['source_code']
        return unless source

        { 'bytes' => source.bytesize, 'lines' => source.lines.size }
      end
    end
  end
end
