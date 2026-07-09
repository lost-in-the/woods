# frozen_string_literal: true

require 'json'
require 'pathname'
require 'set'

module Woods
  module Erd
    # Projects extracted routes + controllers into a slim entry-point index
    # consumed by the frontend Journey Mode.
    #
    # Emits one row per GET route whose controller is present in the
    # extracted controllers directory. Rows are sorted by path for
    # deterministic schema output.
    class EntryPointIndexBuilder
      def initialize(output_dir)
        @output_dir = Pathname.new(output_dir)
      end

      # @return [Array<Hash{String => String}>] sorted entry-point rows
      def build
        return [] unless routes_dir.directory?

        controllers = load_controller_identifiers
        entries = load_route_units.filter_map { |unit| project(unit, controllers) }
        entries.sort_by { |e| e['path'] }
      end

      private

      def routes_dir
        @output_dir.join('routes')
      end

      def controllers_dir
        @output_dir.join('controllers')
      end

      def load_route_units
        routes_dir.children
                  .select { |f| f.extname == '.json' && f.basename.to_s != '_index.json' }
                  .map { |f| JSON.parse(f.read) }
      end

      def load_controller_identifiers
        return Set.new unless controllers_dir.directory?

        controllers_dir.children
                       .select { |f| f.extname == '.json' && f.basename.to_s != '_index.json' }
                       .to_set { |f| JSON.parse(f.read)['identifier'] }
      end

      def project(unit, controllers)
        meta = unit['metadata'] || {}
        verb = (meta['http_method'] || meta['verb']).to_s.upcase
        return nil unless verb == 'GET'

        controller_id = controller_identifier(unit)
        return nil unless controller_id && controllers.include?(controller_id)

        {
          'identifier' => controller_id,
          'verb' => 'GET',
          'path' => meta['path'].to_s,
          'action' => meta['action'].to_s
        }
      end

      # Resolve the controller class identifier from the route unit.
      #
      # Prefers the explicit controller dependency edge (target of type "controller"),
      # which carries the full class name (e.g. "StaticPagesController"). Falls back
      # to the short controller name from metadata for backwards compatibility.
      def controller_identifier(unit)
        deps = unit['dependencies'] || []
        controller_dep = deps.find { |d| d['type'].to_s == 'controller' }
        controller_dep&.fetch('target', nil)
      end
    end
  end
end
