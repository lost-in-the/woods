# frozen_string_literal: true

module Woods
  module MCP
    # Orders a traversal's rows for the indented text renderers (#1041).
    #
    # The reader lists nodes breadth first, so indenting that flat list by
    # depth puts a node under whichever row came just before it, which can be
    # a sibling with no edge to it. This places each row directly under a
    # listed row one depth shallower whose `deps` name it (the first such row
    # in walk order). A row with no listed parent (its parent was filtered
    # out or is on another page) is detached: it is shown at the top level
    # with its depth, so no edge is implied.
    module TraversalTree
      # One row to print.
      Row = Struct.new(:id, :info, :level, :detached, keyword_init: true)

      # @param nodes [Hash{String => Hash}] the traversal's `nodes`, in walk order
      # @return [Array<Row>] every node once, each child after its parent
      def self.rows(nodes)
        entries = nodes.to_a
        parents = parent_index(entries)
        children = Hash.new { |hash, key| hash[key] = [] }
        tops = []
        entries.each do |id, info|
          parent = depth(info).positive? ? parents[[id.to_s, depth(info)]] : nil
          parent ? children[parent] << [id, info] : tops << [id, info]
        end

        tops.each_with_object([]) do |(id, info), rows|
          append(rows, id, info, 0, children, detached: depth(info).positive?)
        end
      end

      # @param info [Hash] one node's entry
      # @return [Integer]
      def self.depth(info)
        (info[:depth] || info['depth'] || 0).to_i
      end

      # First listed row one depth shallower that names each child.
      #
      # @param entries [Array<Array(String, Hash)>]
      # @return [Hash{Array(String, Integer) => String}] [child, child depth] => parent id
      def self.parent_index(entries)
        entries.each_with_object({}) do |(id, info), index|
          Array(info[:deps] || info['deps']).each do |dep|
            index[[dep.to_s, depth(info) + 1]] ||= id
          end
        end
      end

      # @return [void]
      def self.append(rows, id, info, level, children, detached: false)
        rows << Row.new(id: id, info: info, level: level, detached: detached)
        children[id].each { |child_id, child_info| append(rows, child_id, child_info, level + 1, children) }
      end

      private_class_method :parent_index, :append
    end
  end
end
