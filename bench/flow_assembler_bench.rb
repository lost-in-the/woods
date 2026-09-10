# frozen_string_literal: true

# Benchmark: Woods::FlowAssembler through Woods::FlowPrecomputer
#
# What this measures:
#   With precompute_flows on, one FlowPrecomputer run assembles a flow per
#   controller action, and every one of them walks the dependency graph into
#   the services, models and jobs the action reaches. One FlowAssembler serves
#   the whole run, so the same handful of shared services is reached over and
#   over.
#
#   The bench builds a synthetic index on disk in the extractor's own layout
#   (435 controllers x 7 actions, 3000 services, each unit padded with filler
#   methods so parsing costs something realistic) and times:
#
#   1. precompute        (every controller, the full-extraction path)
#   2. recompute_delta   (10 controllers, the incremental path)
#
# How to run:
#   bundle exec ruby bench/flow_assembler_bench.rb
#   CONTROLLERS=100 SERVICES=500 bundle exec ruby bench/flow_assembler_bench.rb
#
# What "good" looks like:
#   precompute scales with the number of distinct units reached, not with
#   controllers x actions. Before the per-instance unit and AST memos it was
#   the latter.

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)

require 'benchmark'
require 'digest'
require 'fileutils'
require 'json'
require 'tmpdir'
require 'woods/extracted_unit'
require 'woods/dependency_graph'
require 'woods/flow_precomputer'

CONTROLLERS = Integer(ENV.fetch('CONTROLLERS', 435))
SERVICES = Integer(ENV.fetch('SERVICES', 3000))
ACTIONS = %w[index show create update destroy new edit].freeze

# Padding, so a unit's source is the size of a real one rather than four lines.
FILLER = Array.new(60) do |i|
  "  def helper_#{i}(value)\n    value.to_s.upcase.strip.split(',').map { |part| part.to_i }\n  end"
end.join("\n")

def write_unit(dir, type, identifier, source, metadata)
  base = identifier.gsub('::', '__').gsub(/[^a-zA-Z0-9_-]/, '_')
  filename = "#{base}_#{Digest::SHA256.hexdigest(identifier)[0, 8]}.json"
  File.write(
    File.join(dir, filename),
    JSON.generate('type' => type, 'identifier' => identifier,
                  'file_path' => "/app/#{identifier}.rb",
                  'source_code' => source, 'metadata' => metadata)
  )
end

def register(graph, type, identifier)
  graph.register(
    Woods::ExtractedUnit.new(type: type, identifier: identifier, file_path: "/app/#{identifier}.rb")
  )
end

def build_services(root, graph, random, service_names)
  SERVICES.times do |i|
    calls = Array.new(4) { "    #{service_names.sample(random: random)}.where(id: id).first" }.join("\n")
    write_unit(File.join(root, 'services'), 'service', "Svc#{i}",
               "class Svc#{i}\n  def call\n#{calls}\n  end\n#{FILLER}\nend", {})
    register(graph, :service, "Svc#{i}")
  end
end

def build_controllers(root, graph, random, service_names)
  Array.new(CONTROLLERS) do |i|
    identifier = "Ctrl#{i}Controller"
    body = ACTIONS.map do |action|
      calls = Array.new(3) { "    #{service_names.sample(random: random)}.new(params).call" }.join("\n")
      "  def #{action}\n#{calls}\n    render json: {}\n  end"
    end.join("\n")
    routes = ACTIONS.to_h { |action| [action, [{ 'verb' => 'GET', 'path' => "/#{i}/#{action}" }]] }
    write_unit(File.join(root, 'controllers'), 'controller', identifier,
               "class #{identifier} < ApplicationController\n#{body}\n#{FILLER}\nend",
               'actions' => ACTIONS, 'routes' => routes)
    register(graph, :controller, identifier)

    unit = Woods::ExtractedUnit.new(type: :controller, identifier: identifier, file_path: "/app/#{identifier}.rb")
    unit.metadata = { actions: ACTIONS, routes: routes }
    unit
  end
end

def build_index(root)
  random = Random.new(7)
  service_names = Array.new(SERVICES) { |i| "Svc#{i}" }
  graph = Woods::DependencyGraph.new

  %w[controllers services flows].each { |dir| FileUtils.mkdir_p(File.join(root, dir)) }
  build_services(root, graph, random, service_names)

  [graph, build_controllers(root, graph, random, service_names)]
end

def report(label, &block)
  elapsed = Benchmark.realtime(&block)
  puts format('%<label>-46s %<elapsed>8.3fs', label: label, elapsed: elapsed)
end

root = Dir.mktmpdir('woods_flow_bench')
begin
  graph, units = build_index(root)
  puts "index: #{CONTROLLERS} controllers x #{ACTIONS.size} actions, #{SERVICES} services"
  puts

  report("precompute (#{CONTROLLERS * ACTIONS.size} flows)") do
    Woods::FlowPrecomputer.new(units: units, graph: graph, output_dir: root).precompute
  end

  report('recompute_delta (10 controllers)') do
    Woods::FlowPrecomputer.new(units: [], graph: graph, output_dir: root)
                          .recompute_delta(touched_units: units.first(10), removed_identifiers: [])
  end
ensure
  FileUtils.remove_entry(root)
end
