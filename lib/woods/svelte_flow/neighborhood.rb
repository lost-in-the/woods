# frozen_string_literal: true

require 'set'
require_relative 'edge_data'

module Woods
  module SvelteFlow
    # BFS expansion over a graph's serialized adjacency maps
    # ({ nodes:, edges:, reverse: } as produced by DependencyGraph#to_h).
    module Neighborhood
      module_function

      # Expand one or more seed nodes by `depth` hops, traversing forward and
      # (unless a via filter is set) reverse edges.
      #
      # @param seeds [String, Array<String>, Set<String>] Seed identifier(s)
      # @param depth [Integer] Hops to expand (0 = seeds only)
      # @param adjacency [Hash] { nodes:, edges:, reverse: }
      # @param via_set [Set<Symbol>, nil] Optional relationship filter
      # @return [Set<String>] Visited identifiers (seeds included)
      def collect(seeds, depth, adjacency, via_set: nil)
        visited = seeds.is_a?(Set) ? seeds.dup : Set.new(Array(seeds))
        frontier = visited.to_a

        depth.times do
          next_frontier = []
          frontier.each do |current|
            neighbors_of(current, adjacency, via_set).each do |dep|
              next if visited.include?(dep)

              visited.add(dep)
              next_frontier << dep
            end
          end
          frontier = next_frontier
        end

        visited
      end

      # Neighbor identifiers of a node for BFS expansion. Forward edges are
      # { target:, via: } hashes; reverse edges are plain identifier strings.
      # When a `via_set` is given, only forward edges of those relationships are
      # followed (reverse edges are unlabeled after serialization, so they are
      # excluded rather than followed under an unknown relationship).
      #
      # @return [Array<String>]
      def neighbors_of(current, adjacency, via_set)
        entries = adjacency[:edges][current] || []
        entries = entries.select { |e| via_set.include?(EdgeData.via(e)) } if via_set
        forward = EdgeData.targets(entries)
        via_set ? forward : forward + (adjacency[:reverse][current] || [])
      end
    end
  end
end
