# frozen_string_literal: true

require 'digest'
require 'json'
require_relative 'builder'

module Woods
  module Diagrams
    # The typed edges around one unit as a flowchart (`flowchart LR`): each
    # node is declared once as `identifier (type)`, each edge labelled with
    # its `via`, the unit itself classed `focus`. Breadth-first over the published edges and
    # `reverse_via`, one level per depth, each edge once; variant nodes are
    # followed by their own edges. `types` keeps the edges whose first-reached
    # endpoint has one of those types; `via` keeps those mechanisms.
    class Neighbourhood < Builder
      KIND = 'neighbourhood'
      OPTIONS = %w[direction types via].freeze
      DIRECTIONS = %w[both dependents dependencies].freeze

      # Flowchart node budget (R-4).
      NODE_BUDGET = 150

      Edge = Struct.new(:from, :from_type, :via, :to, :to_type, :reached_type, keyword_init: true)

      # @return [Array<Edge>] the edges drawn, after the filters
      def edges
        @edges ||= collect.select { |edge| keep_type?(edge) && keep_via?(edge) }
      end

      private

      def prepare
        node = @type ? @source.graph_node(@identifier, type: @type) : @source.graph_node(@identifier)
        raise UnitNotFound, "No unit #{@identifier}#{" of type #{@type}" if @type} in this generation" unless node

        @type ||= node['type'].to_s
        @focus = [@identifier, @type]
        @direction = choice('direction', DIRECTIONS, 'both')
        @types = string_list('types')
        @via = string_list('via')
      end

      def budget
        NODE_BUDGET
      end

      # @return [Integer] distinct typed units drawn, the unit included
      def size
        edges.flat_map { |e| [[e.from, e.from_type], [e.to, e.to_type]] }.push(@focus).uniq.size
      end

      def refusal_text
        return nil unless size > NODE_BUDGET

        "#{size} units is over the flowchart budget of #{NODE_BUDGET}; narrow the types or mechanisms to draw it"
      end

      def extra_details
        { 'direction' => @direction, 'types' => @types, 'via' => @via, 'edges' => edges.size }
      end

      # Each unit declared once with its label, the unit first, then the
      # edges by id; the unit carries the `focus` class, which the text
      # declares.
      def mermaid
        lines = ['flowchart LR'] + mermaid_nodes.map { |node| "  #{mermaid_node(*node)}" }
        edges.each do |edge|
          arrow = edge.via.empty? ? '-->' : "-->|#{edge.via}|"
          lines << "  #{node_id(edge.from, edge.from_type)} #{arrow} #{node_id(edge.to, edge.to_type)}"
        end
        (lines + ['  classDef focus stroke-width:3px', "  class #{node_id(*@focus)} focus"]).join("\n")
      end

      def mermaid_nodes
        ([@focus] + edges.flat_map { |edge| [[edge.from, edge.from_type], [edge.to, edge.to_type]] }).uniq
      end

      def node_id(identifier, type)
        "n_#{Digest::SHA256.hexdigest([type, identifier].to_json)[0, 16]}"
      end

      def mermaid_node(identifier, type)
        "#{node_id(identifier, type)}[#{"#{identifier} (#{type})".to_json}]"
      end

      def collect
        seen = {}
        frontier = [@focus]
        @depth.times { frontier = frontier.flat_map { |node| expand(node, seen) }.uniq }
        seen.values
      end

      def expand(node, seen)
        around(node).filter_map do |edge|
          key = [edge.from, edge.from_type, edge.via, edge.to, edge.to_type]
          next if seen.key?(key)

          seen[key] = edge
          reached = [edge.from, edge.from_type] == node ? [edge.to, edge.to_type] : [edge.from, edge.from_type]
          edge.reached_type = reached.last
          reached
        end
      end

      def around(node)
        (@direction == 'dependents' ? [] : outgoing(node)) + (@direction == 'dependencies' ? [] : incoming(node))
      end

      def outgoing(node)
        identifier, type = node
        own = @source.type_of(identifier) == type
        raw = own ? @source.graph.dig('edges', identifier) : @source.graph_node(identifier, type: type)&.dig('edges')
        Array(raw).map do |edge|
          edge = { 'target' => edge } unless edge.is_a?(Hash) # a graph from before typed edges
          Edge.new(from: identifier, from_type: type, via: edge['via'].to_s, to: edge['target'].to_s,
                   to_type: edge['type'] || @source.type_of(edge['target'].to_s))
        end
      end

      def incoming(node)
        identifier, type = node
        reverse_edges(identifier).filter_map do |edge|
          target_type = edge['type'] || @source.type_of(identifier)
          next unless target_type == type

          Edge.new(from: edge['source'], from_type: edge['source_type'] || @source.type_of(edge['source']),
                   via: edge['via'].to_s, to: identifier, to_type: target_type)
        end
      end

      # `reverse_via`, or the bare `reverse` sources of a graph from before it.
      def reverse_edges(identifier)
        graph = @source.graph
        return Array(graph.dig('reverse_via', identifier)) if graph.key?('reverse_via')

        Array(graph.dig('reverse', identifier)).map { |source| { 'source' => source.to_s } }
      end

      def keep_type?(edge)
        @types.nil? || edge.reached_type.nil? || @types.include?(edge.reached_type)
      end

      def keep_via?(edge)
        @via.nil? || @via.include?(edge.via)
      end
    end
  end
end
