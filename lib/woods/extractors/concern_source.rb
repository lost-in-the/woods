# frozen_string_literal: true

require_relative 'source_nesting'

module Woods
  module Extractors
    # Source owned by one promoted module. Keep byte offsets and line numbers
    # while blanking sibling declarations instead of scanning their contents.
    class ConcernSource
      include SourceNesting

      def initialize(source)
        @source = source
        @parsed = Woods::ParseCache.parse(source)
      end

      def for_owner(owner)
        return unless @parsed.success?

        ranges = []
        each_syntax_declaration(@parsed.value) do |kind, _name, qualified, node|
          ranges << node.location if kind == 'module' && qualified.delete_prefix('::') == owner
        end
        return if ranges.empty?

        bytes = @source.b.gsub(/[^\n]/, ' ')
        ranges.each { |location| bytes[location.start_offset, location.length] = location.slice.b }
        blank_nested_owners(bytes, owner, ranges)
        bytes.force_encoding(@source.encoding)
      end

      def blank_nested_owners(bytes, owner, ranges)
        each_syntax_declaration(@parsed.value) do |_kind, _name, qualified, node|
          next if [owner, "#{owner}::ClassMethods"].include?(qualified.delete_prefix('::'))

          location = node.location
          next unless ranges.any? do |range|
            range.start_offset < location.start_offset && location.end_offset < range.end_offset
          end

          bytes[location.start_offset, location.length] = location.slice.b.gsub(/[^\n]/, ' ')
        end
      end
      private :blank_nested_owners

      # Concern class methods may be declared in a class_methods block or in
      # the conventional ClassMethods module, including reopened declarations.
      def class_methods
        return [] unless @parsed.success?

        names = []
        pending = [[@parsed.value, false]]
        until pending.empty?
          node, class_scope = pending.pop
          if node.is_a?(Prism::DefNode)
            names << node.name.to_s if class_scope && node.receiver.nil?
            next
          end
          class_scope ||= node.is_a?(Prism::ModuleNode) && node.constant_path.location.slice == 'ClassMethods'
          class_scope ||= node.is_a?(Prism::CallNode) && node.name == :class_methods && node.receiver.nil?
          node.compact_child_nodes.each { |child| pending << [child, class_scope] }
        end
        names.uniq.sort
      end
    end
  end
end
