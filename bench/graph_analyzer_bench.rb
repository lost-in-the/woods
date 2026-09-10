# frozen_string_literal: true

# Benchmark: Woods::GraphAnalyzer
#
# What this measures:
#   GraphAnalyzer#analyze runs on every extraction, full or incremental, and
#   its cost is a function of the graph rather than of the change set. On a
#   large host app that made it the fixed floor of every incremental run. Two
#   phases dominate:
#
#   1. #cycles   (one cycle per DFS back-edge, each canonicalized into a
#                  signature. Uncapped, a dense graph yields tens of thousands
#                  of them, most thousands of nodes long)
#   2. #bridges  (200 whole-graph BFS runs for sampled betweenness)
#
#   The bench builds a synthetic graph in the shape of a large Rails app
#   (8201 units, 4 outgoing edges each, 30% of them pointing at one of 50
#   hubs) and reports each phase.
#
# How to run:
#   bundle exec ruby bench/graph_analyzer_bench.rb
#   NODES=20000 bundle exec ruby bench/graph_analyzer_bench.rb
#
# What "good" looks like:
#   #cycles under the default caps finishes in tens of milliseconds. The
#   uncapped row is printed alongside it as the comparison, and is expected to
#   be two to three orders of magnitude slower on this graph.

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)

require 'benchmark'
require 'woods/extracted_unit'
require 'woods/dependency_graph'
require 'woods/graph_analyzer'

NODES = Integer(ENV.fetch('NODES', 8201))
EDGES = Integer(ENV.fetch('EDGES', 4))
HUBS = 50
TYPES = %i[model controller service job serializer component].freeze

def build_graph
  random = Random.new(1234)
  graph = Woods::DependencyGraph.new

  NODES.times do |i|
    type = TYPES[i % TYPES.size]
    unit = Woods::ExtractedUnit.new(
      type: type, identifier: "Unit#{i}", file_path: "/app/app/#{type}s/unit_#{i}.rb"
    )
    edges = Array.new(EDGES) do
      target = random.rand < 0.3 ? "Unit#{random.rand(HUBS)}" : "Unit#{random.rand(NODES)}"
      { target: target, via: :association }
    end
    unit.dependencies = edges.uniq { |dependency| dependency[:target] }
    graph.register(unit)
  end

  graph
end

def report(label)
  result = nil
  elapsed = Benchmark.realtime { result = yield }
  puts format('%<label>-42s %<elapsed>8.3fs  %<result>s', label: label, elapsed: elapsed, result: result)
end

graph = build_graph
puts "graph: #{NODES} nodes, up to #{EDGES} edges each, #{HUBS} hubs"
puts

capped = Woods::GraphAnalyzer.new(graph)
report('cycles (default caps)') do
  "#{capped.cycles.size} cycles, truncated=#{capped.cycle_limit_reached?}"
end

uncapped = Woods::GraphAnalyzer.new(graph, cycle_limit: nil, cycle_max_length: nil)
report('cycles (uncapped)') do
  "#{uncapped.cycles.size} cycles, truncated=#{uncapped.cycle_limit_reached?}"
end

report('bridges(limit: 10)') { "#{Woods::GraphAnalyzer.new(graph).bridges(limit: 10).size} bridges" }

report('analyze (whole report)') { "#{Woods::GraphAnalyzer.new(graph).analyze[:stats].size} stats" }
