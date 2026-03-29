# frozen_string_literal: true

module Woods
  module SvelteFlow
    # Computes x/y positions for Svelte Flow nodes using layered DAG layout.
    #
    # Uses Kahn's algorithm for topological sorting with PageRank-based
    # tiebreaking for cycles. Nodes are arranged in layers (left-to-right)
    # with vertical spacing within each layer.
    #
    # @example
    #   layout = Layout.new(
    #     edges: { "A" => ["B", "C"], "B" => ["C"], "C" => [] },
    #     pagerank: { "A" => 0.5, "B" => 0.3, "C" => 0.2 }
    #   )
    #   positions = layout.compute
    #   # => { "A" => { "x" => 0, "y" => 0 }, "B" => { "x" => 300, "y" => 0 }, ... }
    #
    class Layout
      LAYER_SPACING_X = 300
      NODE_SPACING_Y = 100

      # @param edges [Hash<String, Array<String>>] Forward edges: source => [targets]
      # @param pagerank [Hash<String, Float>] PageRank scores for tiebreaking
      def initialize(edges:, pagerank: {})
        @edges = edges
        @pagerank = pagerank
        @node_ids = edges.keys
      end

      # Compute positions for all nodes.
      #
      # @return [Hash<String, Hash>] node_id => { "x" => Integer, "y" => Integer }
      def compute
        layers = assign_layers
        assign_positions(layers)
      end

      # Compute positions for a flow document (vertical sequential layout).
      #
      # @param steps [Array<Hash>] Flow document steps with :unit keys
      # @return [Hash<String, Hash>] node_id => { "x" => Integer, "y" => Integer }
      def self.flow_positions(steps)
        positions = {}
        steps.each_with_index do |step, idx|
          unit = step[:unit] || step['unit']
          next unless unit
          next if positions.key?(unit)

          positions[unit] = { 'x' => 0, 'y' => idx * 150 }
        end
        positions
      end

      # Compute positions for domain clusters arranged in a grid.
      #
      # @param clusters [Array<Hash>] Domain cluster data from GraphAnalyzer
      # @param edges [Hash<String, Array<String>>] Forward edges for intra-cluster layout
      # @param pagerank [Hash<String, Float>] PageRank scores
      # @return [Hash<String, Hash>] node_id => { "x" => Integer, "y" => Integer }
      def self.cluster_positions(clusters, edges: {}, pagerank: {}) # rubocop:disable Metrics
        positions = {}
        cols = Math.sqrt(clusters.size).ceil
        cols = 1 if cols.zero?

        clusters.each_with_index do |cluster, idx|
          members = cluster[:members] || cluster['members'] || []
          next if members.empty?

          grid_col = idx % cols
          grid_row = idx / cols
          offset_x = grid_col * 800
          offset_y = grid_row * 600

          # Local layered layout within the cluster
          local_edges = members.each_with_object({}) do |m, h|
            targets = (edges[m] || []) & members
            h[m] = targets
          end

          local_layout = new(edges: local_edges, pagerank: pagerank)
          local_positions = local_layout.compute

          local_positions.each do |node_id, pos|
            positions[node_id] = {
              'x' => pos['x'] + offset_x,
              'y' => pos['y'] + offset_y
            }
          end
        end

        positions
      end

      private

      # Assign nodes to layers using modified Kahn's algorithm.
      # Handles cycles by breaking ties with PageRank (lower rank nodes are placed later).
      #
      # @return [Array<Array<String>>] Layers of node identifiers
      def assign_layers # rubocop:disable Metrics
        in_degree = Hash.new(0)
        @node_ids.each { |id| in_degree[id] ||= 0 }

        @edges.each_value do |targets|
          targets.each do |t|
            in_degree[t] += 1 if @node_ids.include?(t)
          end
        end

        # Start with nodes that have no incoming edges
        queue = @node_ids.select { |id| in_degree[id].zero? }
        queue.sort_by! { |id| -(@pagerank[id] || 0) }

        layers = []
        placed = Set.new

        until queue.empty?
          layers << queue.dup
          queue.each { |id| placed.add(id) }

          next_queue = []
          queue.each do |id|
            (@edges[id] || []).each do |target|
              next unless @node_ids.include?(target)
              next if placed.include?(target)

              in_degree[target] -= 1
              next_queue << target if in_degree[target] <= 0
            end
          end

          queue = next_queue.uniq.sort_by { |id| -(@pagerank[id] || 0) }
        end

        # Handle remaining nodes (in cycles) — place them in a final layer
        remaining = @node_ids - placed.to_a
        unless remaining.empty?
          remaining.sort_by! { |id| -(@pagerank[id] || 0) }
          layers << remaining
        end

        layers
      end

      # Assign x/y coordinates from layers.
      #
      # @param layers [Array<Array<String>>] Node layers
      # @return [Hash<String, Hash>] node_id => { "x" => Integer, "y" => Integer }
      def assign_positions(layers)
        positions = {}

        layers.each_with_index do |layer, layer_idx|
          # Sort within layer by namespace for visual grouping
          sorted = layer.sort
          sorted.each_with_index do |node_id, pos_idx|
            positions[node_id] = {
              'x' => layer_idx * LAYER_SPACING_X,
              'y' => pos_idx * NODE_SPACING_Y
            }
          end
        end

        positions
      end
    end
  end
end
