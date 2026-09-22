# frozen_string_literal: true

require 'json'
require 'pathname'
require_relative '../../lib/woods/dependency_graph'
require_relative 'response'

module WoodsDevelopment
  module TypeSafe
    # Projects graph facts for explicit source paths without loading source code.
    # Standalone-only: the native loader otherwise rebases paths to Rails.root.
    class GraphEvidence
      # @param data [Hash] parsed string-keyed Woods dependency graph JSON
      # @return [GraphEvidence] standalone graph evidence adapter
      # @raise [InvalidEvidence] for invalid graph shape or an ambient Rails root
      def initialize(data)
        check(data.is_a?(Hash) && data['nodes'].is_a?(Hash) && data['file_map'].is_a?(Hash),
              'Expected Woods graph nodes and file_map objects')
        check(Woods::DependencyGraph.graph_root.nil?, 'Graph evidence requires a standalone process without Rails.root')
        @graph = Woods::DependencyGraph.from_h(data)
        @node_paths = index_node_paths(data)
      rescue NoMethodError, ArgumentError, TypeError
        raise InvalidEvidence, 'Invalid Woods graph evidence', cause: nil
      end

      # Relative paths and absolute paths inside the explicit root are equivalent.
      # Foreign absolute paths are never rebased; file-map fallbacks stay visible.
      #
      # @param path [String] relative source path or absolute path inside root
      # @param root [String, Pathname] explicit absolute source root
      # @return [Array<Hash>] independent JSON-compatible typed unit records, sorted by identifier and type
      # @raise [InvalidEvidence] for invalid roots or unsafe/out-of-root paths
      def for_path(path, root:)
        paths = lookup_paths(path, root)
        pairs = paths.flat_map { |candidate| @graph.units_for_path(candidate) + @node_paths.fetch(candidate, []) }
        pairs.uniq.sort_by { |identifier, type| [identifier, type.to_s] }.map do |identifier, type|
          JSON.parse(JSON.generate(record(identifier, type)))
        end
      end

      private

      def index_node_paths(data)
        identifiers = data.fetch('nodes').keys + Array(data['variants']).filter_map do |variant|
          variant['identifier'] if variant.is_a?(Hash)
        end
        identifiers.uniq.each_with_object({}) do |identifier, paths|
          @graph.node_types(identifier).each do |type|
            path = @graph.node(identifier, type: type)[:file_path]
            (paths[path] ||= []) << [identifier, type] if path
          end
        end
      end

      def record(identifier, type)
        {
          identifier: identifier,
          type: type,
          node: @graph.node(identifier, type: type),
          edges: @graph.edge_records(identifier, type: type)
        }
      end

      def lookup_paths(path, root)
        prefix = root_prefix(root)
        check(path.is_a?(String), 'Invalid graph evidence path')
        relative = path.start_with?('/') ? path.delete_prefix(prefix) : path
        validate_relative_path(relative)
        [relative, File.join(prefix, relative)]
      rescue ArgumentError, TypeError, EncodingError
        raise InvalidEvidence, 'Invalid graph evidence path', cause: nil
      end

      def root_prefix(root)
        check(root.is_a?(String) || root.is_a?(Pathname), 'Invalid graph source root')
        check(root.to_s.start_with?('/'), 'Graph source root must be absolute')
        File.join(File.expand_path(root), '')
      end

      def validate_relative_path(relative)
        check(!relative.empty? && !relative.start_with?('/') && !relative.match?(/\A[A-Za-z]:|[\x00\\]/),
              'Graph evidence path must be inside the source root')
        check(relative.split('/', -1).none? { |part| part.empty? || part == '.' || part == '..' },
              'Invalid graph evidence path component')
      end

      def check(condition, message)
        raise InvalidEvidence, message unless condition
      end
    end
  end
end
