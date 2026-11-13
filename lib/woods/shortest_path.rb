# frozen_string_literal: true

require_relative 'edge_evidence'

module Woods
  # A shortest chain of published forward edges from one unit to another:
  # the search behind {DependencyGraph#shortest_path} and the Index Server's
  # `path` tool.
  #
  # The search is breadth-first over typed nodes, `[identifier, type]`, so the
  # first path found is a shortest one. An edge names its target by identifier
  # alone; it therefore reaches every unit registered under that identifier,
  # and a hop to a shared identifier lists them all under `:target_types`.
  # Neighbours are visited sorted by identifier, then type: the answer is a
  # function of the graph's content, never of the order units were registered
  # in, which differs between a full and an incremental extraction.
  #
  # A path is never routed through a documentation unit
  # ({DependencyGraph::DOCUMENTATION_UNIT_TYPES}), which describes the code
  # instead of being part of it. One may still be an endpoint.
  #
  # Two bounds stop a search early: `max_depth` hops and `max_nodes` reached
  # units. A stopped search answers `exhaustive: false` with a
  # `partial_reason`, so "no path within the bound" is never read as "no path
  # exists".
  #
  # Every hop says how Woods knows its edge ({EdgeEvidence}): the strongest
  # class among the edge's vias, read by the type of the unit the edge
  # leaves. A path is as well supported as its weakest hop.
  class ShortestPath
    DEFAULT_MAX_DEPTH = 10
    DEFAULT_MAX_NODES = 10_000
    DIRECTIONS = %w[forward either].freeze

    # @param graph [DependencyGraph]
    # @param max_depth [Integer] most hops a path may have
    # @param max_nodes [Integer] most units one search may reach, the start included
    def initialize(graph, max_depth: DEFAULT_MAX_DEPTH, max_nodes: DEFAULT_MAX_NODES)
      @graph = graph
      @max_depth = [max_depth.to_i, 0].max
      @max_nodes = [max_nodes.to_i, 1].max
    end

    # @param from [Array(String, Symbol)] the start, `[identifier, type]`
    # @param to [Array(String, Symbol)] the target, `[identifier, type]`
    # @param direction [String] `forward` follows edges from +from+ toward
    #   +to+; `either` also searches from +to+ toward +from+ when that finds nothing
    # @return [Hash] `from:` and `to:` (`{ identifier:, type: }`), `found:`,
    #   `direction:` (`forward` or `reverse`, nil when not found), `hop_count:`
    #   (nil when not found), `hops:` in the order the edges run (`{ source:,
    #   source_type:, target:, target_type:, via: [String], evidence: }`, plus
    #   `target_types:` for a shared identifier and `evidence_mixed: true`
    #   when the evidence is a floor), `evidence:` (the weakest hop's class,
    #   with `weakest_hop:`, counted from 1, unless every hop is `reflected`,
    #   and `evidence_mixed: true` when that hop's is a floor; absent with no
    #   hops) and `searches:` (one
    #   `{ direction:, exhaustive:, max_depth:, max_nodes:, visited_nodes: }`
    #   per search run, with `partial_reason:` when a bound stopped it). Only
    #   when not found: `exhaustive:` (whether every search ran to its end)
    #   and, when one did not, `partial_reason:` (`max_depth` or `node_budget`)
    # @raise [ArgumentError] for a direction outside {DIRECTIONS}
    def call(from, to, direction: 'forward')
      direction = direction.to_s
      raise ArgumentError, "direction must be one of #{DIRECTIONS.join(', ')}" unless DIRECTIONS.include?(direction)

      searches = [search(from, to, 'forward')]
      searches << search(to, from, 'reverse') if direction == 'either' && !searches.first[:hops]
      result(from, to, searches)
    end

    private

    # @return [Hash] the answer assembled from the searches run, the last of
    #   which is the only one that can have found a path
    def result(from, to, searches)
      hops = searches.last[:hops]
      answer = { from: endpoint(from), to: endpoint(to), found: !hops.nil?, direction: nil, hop_count: nil,
                 hops: [] }
      answer.merge!(hops ? reached(searches.last) : unreached(searches))
      answer[:searches] = searches.map { |search| search.except(:hops) }
      answer
    end

    # @return [Hash]
    def reached(search)
      { direction: search[:direction], hop_count: search[:hops].size, hops: search[:hops] }
        .merge(path_evidence(search[:hops]))
    end

    # @return [Hash] the weakest hop's evidence, and which hop that is
    def path_evidence(hops)
      weakest = EdgeEvidence.weakest(hops.map { |hop| hop[:evidence] })
      return {} unless weakest
      return { evidence: weakest } if weakest == EdgeEvidence::REFLECTED

      index = hops.index { |hop| hop[:evidence] == weakest }
      evidence = { evidence: weakest, weakest_hop: index + 1 }
      evidence[:evidence_mixed] = true if hops[index][:evidence_mixed]
      evidence
    end

    # @return [Hash] whether every search ran to its end, and what stopped the first that did not
    def unreached(searches)
      stopped = searches.filter_map { |search| search[:partial_reason] }.first
      stopped ? { exhaustive: false, partial_reason: stopped } : { exhaustive: true }
    end

    # @return [Hash]
    def endpoint(node)
      { identifier: node.first, type: node.last.to_s }
    end

    # @return [Hash] `hops:` is nil when +goal+ was not reached
    def search(start, goal, direction)
      walk = { parents: { start => nil }, queue: [[start, 0]], stopped: nil }
      hops = start == goal ? [] : walk_to(goal, walk)
      stopped = hops ? nil : walk[:stopped]
      summary = { direction: direction, hops: hops, exhaustive: stopped.nil?, max_depth: @max_depth,
                  max_nodes: @max_nodes, visited_nodes: walk[:parents].size }
      summary[:partial_reason] = stopped if stopped
      summary
    end

    # Breadth-first from the queued start. `parents` doubles as the visited
    # set, which is what keeps a cycle from looping.
    #
    # @return [Array<Hash>, nil] the hops to +goal+, nil when it was not reached
    def walk_to(goal, walk)
      until walk[:queue].empty?
        node, depth = walk[:queue].shift
        outcome = depth < @max_depth ? expand(node, depth, goal, walk) : frontier(node, goal, walk[:parents])
        return trail(goal, walk[:parents]) if outcome == :found

        walk[:stopped] ||= outcome
        break if outcome == 'node_budget'
      end
      nil
    end

    # Admit a node's unvisited neighbours.
    #
    # @return [Symbol, String, nil] `:found`, or `node_budget` when admitting
    #   another unit would pass `max_nodes`
    def expand(node, depth, goal, walk)
      parents = walk[:parents]
      neighbours(node, goal).each do |neighbour, hop|
        next if parents.key?(neighbour)
        return 'node_budget' if neighbour != goal && parents.size >= @max_nodes

        parents[neighbour] = [node, hop]
        return :found if neighbour == goal

        walk[:queue] << [neighbour, depth + 1]
      end
      nil
    end

    # A node at `max_depth` is not expanded. Every node nearer the start has
    # been by now, so an unvisited neighbour here is one only a longer path
    # could reach: the search is then bounded, not exhaustive. The goal is
    # passed on so a document that is the goal counts as such a neighbour;
    # any other document is not a unit a path may continue through.
    #
    # @return [String, nil]
    def frontier(node, goal, parents)
      'max_depth' if neighbours(node, goal).any? { |neighbour, _| !parents.key?(neighbour) }
    end

    # The typed nodes a node's edges reach, with the hop that reaches each,
    # sorted by identifier and then type. A documentation unit is left out
    # unless it is the goal; a target no unit is registered for reaches nothing.
    #
    # @return [Array<Array(Array(String, Symbol), Hash)>]
    def neighbours(node, goal)
      labels_by_target(node).sort.flat_map do |target, labels|
        types = @graph.node_types(target)
        types.filter_map do |type|
          neighbour = [target, type]
          next if DependencyGraph::DOCUMENTATION_UNIT_TYPES.include?(type) && neighbour != goal

          [neighbour, hop(node, neighbour, labels, types)]
        end
      end
    end

    # @return [Hash{String => Array<String, nil>}] every via on the node's edges, by target
    def labels_by_target(node)
      @graph.edge_records(node.first, type: node.last).each_with_object({}) do |edge, by_target|
        (by_target[edge[:target]] ||= []) << edge[:via]&.to_s
      end
    end

    # @return [Hash] one hop, as {#call} documents it
    def hop(source, target, labels, target_types)
      hop = { source: source.first, source_type: source.last.to_s, target: target.first,
              target_type: target.last.to_s, via: labels.compact.uniq.sort }
      hop[:target_types] = target_types.map(&:to_s) if target_types.size > 1
      evidence = EdgeEvidence.edge(hop[:source_type], hop[:via])
      hop[:evidence] = evidence[:evidence]
      hop[:evidence_mixed] = true if evidence[:mixed]
      hop
    end

    # @return [Array<Hash>] the hops from the start to +goal+, in order
    def trail(goal, parents)
      hops = []
      node = goal
      while (step = parents[node])
        node, hop = step
        hops.unshift(hop)
      end
      hops
    end
  end
end
