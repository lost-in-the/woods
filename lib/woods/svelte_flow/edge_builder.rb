# frozen_string_literal: true

require 'set'

module Woods
  module SvelteFlow
    # Converts dependency graph edges into Svelte Flow edge objects.
    #
    # Supports three edge styles:
    # - Dependency edges (default): standard directed edges between units
    # - Flow edges (smoothstep): sequential step connections in execution flows
    # - Boundary edges (straight + animated): cross-cluster connections
    #
    # @example
    #   builder = EdgeBuilder.new(
    #     edges: { "User" => ["Post", "Comment"] },
    #     valid_node_ids: Set.new(["User", "Post", "Comment"]),
    #     cycle_edges: Set.new
    #   )
    #   builder.build  # => [{ "id" => "e-User-Post", "source" => "User", ... }, ...]
    #
    class EdgeBuilder
      # @param edges [Hash<String, Array<String>>] Forward edges: source => [targets]
      # @param valid_node_ids [Set<String>] Set of node IDs that exist in the graph
      # @param cycle_edges [Set<Array<String>>] Set of [source, target] pairs that form cycles
      # @param exclude_pairs [Set<Array<String>>] Set of [source, target] pairs to skip
      def initialize(edges:, valid_node_ids:, cycle_edges: Set.new, exclude_pairs: Set.new)
        @edges = edges
        @valid_node_ids = valid_node_ids
        @cycle_edges = cycle_edges
        @exclude_pairs = exclude_pairs
      end

      # Build Svelte Flow edge objects for all dependency edges.
      #
      # @return [Array<Hash>] Svelte Flow edge objects
      def build
        result = []

        @edges.each do |source, targets|
          next unless @valid_node_ids.include?(source)

          targets.each do |target|
            next unless @valid_node_ids.include?(target)
            next if @exclude_pairs.include?([source, target])

            result << build_dependency_edge(source, target)
          end
        end

        result
      end

      # Build Svelte Flow edges for a flow document's sequential steps.
      #
      # @param steps [Array<Hash>] Flow document steps with :unit keys
      # @return [Array<Hash>] Svelte Flow edge objects
      def self.flow_edges(steps)
        edges = []
        prev_unit = nil

        steps.each do |step|
          unit = step[:unit] || step['unit']
          next unless unit

          if prev_unit && prev_unit != unit
            edges << {
              'id' => "e-flow-#{prev_unit}-#{unit}",
              'source' => prev_unit,
              'target' => unit,
              'type' => 'smoothstep',
              'data' => { 'relationship' => 'flow_step' }
            }
          end

          prev_unit = unit
        end

        edges.uniq { |e| e['id'] }
      end

      # Build Svelte Flow edges for domain cluster boundary connections.
      #
      # @param boundary_edges [Array<Hash>] Boundary edges from GraphAnalyzer
      #   with :from, :to, :via keys
      # @param valid_node_ids [Set<String>] Set of valid node IDs
      # @return [Array<Hash>] Svelte Flow edge objects
      def self.boundary_edges(boundary_edges, valid_node_ids:)
        boundary_edges.filter_map do |edge|
          from = edge[:from] || edge['from']
          to = edge[:to] || edge['to']
          next unless valid_node_ids.include?(from) && valid_node_ids.include?(to)

          {
            'id' => "e-boundary-#{from}-#{to}",
            'source' => from,
            'target' => to,
            'type' => 'straight',
            'animated' => true,
            'data' => {
              'relationship' => 'boundary',
              'via' => edge[:via] || edge['via']
            }
          }
        end
      end

      private

      # Build a single dependency edge.
      #
      # @param source [String] Source node ID
      # @param target [String] Target node ID
      # @return [Hash] Svelte Flow edge object
      def build_dependency_edge(source, target)
        is_cycle = @cycle_edges.include?([source, target])

        edge = {
          'id' => "e-#{source}-#{target}",
          'source' => source,
          'target' => target,
          'type' => 'default',
          'data' => {
            'relationship' => 'dependency',
            'isCycle' => is_cycle
          }
        }
        edge['animated'] = true if is_cycle
        edge
      end
    end
  end
end
