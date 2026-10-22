# frozen_string_literal: true

require 'digest'
require_relative 'value'

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

      # @param before [Hash] typed units
      # @param after [Hash] typed units
      def initialize(before, after)
        @before = before
        @after = after
      end

      # @return [Array<Hash>] changes sorted by identifier and actual type
      def changes
        (@before.keys | @after.keys).sort.filter_map do |identity|
          before = @before[identity]
          after = @after[identity]
          facets = FIELDS.keys.reject { |facet| fingerprint(before, facet) == fingerprint(after, facet) }
          next if before && after && facets.empty?

          change(identity, before, after, facets)
        end
      end

      private

      def fingerprint(unit, facet)
        return unless unit

        Digest::SHA256.hexdigest(Value.json(unit.fetch(FIELDS.fetch(facet))))
      end

      def change(identity, before, after, facets)
        { 'identifier' => identity[0], 'type' => identity[1], 'status' => status(before, after),
          'facets' => facets, 'categories' => categories(before, after, facets),
          'metadata_keys' => changed_metadata_keys(before, after),
          'diff_stats' => { 'source_before' => source_size(before), 'source_after' => source_size(after) } }
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
          old.key?(key) == current.key?(key) && Value.json(old[key]) == Value.json(current[key])
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
