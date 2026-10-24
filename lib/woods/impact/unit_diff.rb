# frozen_string_literal: true

require_relative 'resolver'
require_relative 'endpoint'
require_relative 'line_diff'
require_relative 'range_diff'
require_relative 'value'

module Woods
  module Impact
    # One unit's unified source diff between two retained generations (#802):
    # the lines that changed in its annotated `source_code`, with context and
    # both endpoints' line numbers, so a reader such as Woods Map draws a diff
    # without diffing payloads itself. The endpoints resolve as
    # {Report.compare}'s do; nothing reads source files, git or Rails.
    class UnitDiff
      SCHEMA_VERSION = 1
      # Diff lines kept across all hunks; past it `coverage` is `truncated`.
      MAX_LINES = 2_000

      # @param index_dir [String, Pathname]
      # @param unit [Hash] the exact typed unit: `'identifier'` and its actual `'type'`
      # @param from [Integer, String] generation number, gen:N or SHA prefix
      # @param to [Integer, String] generation number, gen:N, SHA prefix or now
      # @param options [Hash] `context:` unchanged lines kept around each change, 0..20 (3)
      # @return [Hash] recursively frozen, string-keyed: `schema_version`,
      #   `range` (`from`/`to` provenance), `identifier`, `type`, `status`
      #   (added, removed, modified, unchanged or absent), the `facets`,
      #   `categories` and `metadata_keys` that moved as {Report.compare}'s
      #   `changed` record names them (empty when unchanged; absent when
      #   neither endpoint holds the unit) and, when both endpoints hold it,
      #   `source_changes` (see {LineDiff#unified})
      # @raise [ResolutionError] when a selector names no retained generation
      def self.compare(index_dir, unit:, from:, to: 'now', **options)
        identifier, type = unit.values_at('identifier', 'type')
        raise ArgumentError, 'unit needs an identifier and a type' unless [identifier, type].all?(String)

        context = options.fetch(:context, LineDiff::CONTEXT)
        raise ArgumentError, 'Unsupported unit diff option' unless (options.keys - [:context]).empty?
        raise ArgumentError, 'context must be 0..20' unless context.is_a?(Integer) && (0..20).cover?(context)

        Resolver.new(index_dir).open(from: from, to: to) do |before, after|
          old = before.unit(identifier, type: type)
          new = after.unit(identifier, type: type)
          range = { 'from' => Endpoint.new(before).provenance(from), 'to' => Endpoint.new(after).provenance(to) }
          Value.copy({ 'schema_version' => SCHEMA_VERSION, 'range' => range, 'identifier' => identifier,
                       'type' => type }.merge(body(old, new, context)))
        end
      end

      # @return [Hash] status, the moved facets and, for a unit at both endpoints, its source changes
      def self.body(old, new, context)
        return { 'status' => 'absent' } unless old || new

        identity = [nil, nil]
        record = RangeDiff.new({ identity => old }.compact, { identity => new }.compact).changes.first
        moved = { 'status' => record ? record['status'] : 'unchanged',
                  'facets' => [], 'categories' => [], 'metadata_keys' => [] }
                .merge(record.to_h.slice('facets', 'categories', 'metadata_keys'))
        return moved unless old && new

        moved.merge('source_changes' => LineDiff.new(old['source_code'], new['source_code'])
                                                .unified(max_lines: MAX_LINES, context: context))
      end
      private_class_method :body
    end
  end
end
