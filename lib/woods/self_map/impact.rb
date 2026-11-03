# frozen_string_literal: true

require_relative '../impact/options'
require_relative '../impact/propagation'

module Woods
  module SelfMap
    # File-level candidate impact; inferred ownership never becomes a recorded call.
    class Impact
      def initialize(paths, options: {})
        @paths = paths
        @options = Woods::Impact::Options.new(depth: 4, **options)
      end

      def call(current, baseline: nil)
        endpoints = [endpoint(current, 'current')]
        endpoints << endpoint(baseline, 'baseline') if baseline
        { 'schema_version' => 1, 'scope' => 'static_file_candidates', 'paths' => @paths,
          'parameters' => @options.to_h, 'endpoints' => endpoints,
          'suggested_specs' => suggested_specs(endpoints),
          'coverage' => { 'complete' => false, 'method_calls' => 'not_exhaustive', 'tests' => 'suggestions_only',
                          'baseline' => baseline ? 'selected_snapshot_not_git_verified' : 'unavailable' } }
      end

      private

      def endpoint(snapshot, side)
        roots = snapshot.seeds(@paths)
        units = snapshot.entries.to_h { |entry| [snapshot.identity(entry), entry] }
        graph = owner_graph(snapshot)
        result = Woods::Impact::Propagation.new(graph, units, generation: snapshot.reader.generation_number,
                                                              endpoint: side, options: @options).call(roots)
        attach_locations(result['affected'], units)
        { 'side' => side, 'provenance' => snapshot.provenance, 'seeds' => roots,
          'affected' => result.fetch('affected'), 'traversal' => result.fetch('coverage'),
          'unknowns' => result.fetch('unknowns'), 'unmapped_paths' => @paths - snapshot.mapped_paths,
          'parse_failures' => snapshot.health.fetch('parse_failures', []),
          'parse_coverage' => snapshot.health.empty? ? 'unknown_legacy_map' : 'reported' }
      end

      def attach_locations(affected, units)
        affected.each { |item| item['file_path'] = units.fetch(item.values_at('identifier', 'type'))['file_path'] }
      end

      def owner_graph(snapshot)
        # The published graph stays untouched. Reverse traversal may continue
        # from a referenced method to its owner only through this labelled edge.
        graph = snapshot.graph.merge('reverse_via' => snapshot.graph.fetch('reverse_via').transform_values(&:dup))
        snapshot.entries.select { |entry| entry['type'] == 'ruby_method' }.each do |method|
          bucket = (graph['reverse_via'][method['identifier']] ||= [])
          snapshot.owners(method).each do |owner|
            bucket << { 'source' => owner['identifier'], 'source_type' => owner['type'],
                        'type' => 'ruby_method', 'via' => 'owner_expansion' }
          end
        end
        graph
      end

      def suggested_specs(endpoints)
        candidates = endpoints.flat_map do |endpoint|
          endpoint['affected'].map { |item| item['identifier'] } + endpoint['seeds'].map(&:first)
        end
        candidates.select { |id| id.start_with?('file:spec/') && id.end_with?('_spec.rb') }
                  .map { |id| id.delete_prefix('file:') }.uniq.sort
      end
    end
  end
end
