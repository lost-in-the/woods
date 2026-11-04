# frozen_string_literal: true

# Experimental receipt generator, not a supported CLI or MCP contract.
# bundle exec ruby script/spikes/self_map_impact.rb /tmp/woods-impact-spike
require 'json'
require 'fileutils'
require 'tmpdir'
require 'active_support/core_ext/string/inflections'
require_relative '../../lib/woods/gem_mapper'
require_relative '../../lib/woods/gem_map_affected_specs'
require_relative '../../lib/woods/published_index'
require_relative '../../lib/woods/impact/report'
require_relative '../../lib/woods/impact/renderers'

module SelfMapImpactSpike
  ROOT = File.expand_path('../..', __dir__)
  CASES = {
    'mapper' => ['Woods::GemMapper', 'ruby_class'],
    'mapper_method' => ['Woods::GemMapper#map!', 'ruby_method'],
    'index_reader' => ['Woods::MCP::IndexReader', 'ruby_class'],
    'atomic_file' => ['Woods::AtomicFile', 'ruby_module']
  }.freeze

  def self.write(directory, name, data)
    File.write(File.join(directory, "#{name}.json"), JSON.pretty_generate(data))
  end

  def self.measure(output, name, identity)
    report = Woods::Impact::Report.focus(File.join(output, 'index'), identities: [identity], depth: 3, max_nodes: 1000)
    data = report.to_h
    write(output, name, data)
    write(output, "#{name}_agent", agent_view(data))
    File.write(File.join(output, "#{name}.md"), Woods::Impact::Renderers.markdown(report))
    summarize(data)
  end

  # Keep native evidence intact; classify spec-file witnesses as suggestions.
  # An exact method query and an owner query remain separate experiments.
  def self.agent_view(data)
    specs, components = data['affected'].partition { |item| item['identifier'].start_with?('file:spec/') }
    {
      evidence: 'static source references; execution and coverage unverified',
      focus: data['focus'], endpoint: data['endpoint'], parameters: data['parameters'],
      components: components, suggested_specs: specs,
      limits: data['unknowns'].group_by { |item| item['kind'] }.transform_values(&:size),
      coverage: data['coverage'],
      next_step: 'Inspect witnesses in source; an empty method result needs a separately labelled owner query'
    }
  end

  def self.summarize(data)
    {
      affected: data['affected'].size,
      spec_witnesses: data['affected'].count { |item| item['identifier'].start_with?('file:spec/') },
      tests: data['tests'].size,
      witness_edges: data['affected'].sum { |item| item['paths'].sum { |path| path['edges'].size } },
      coverage: data['coverage'], unknowns: data['unknowns'].group_by { |item| item['kind'] }.transform_values(&:size)
    }
  end

  def self.trace_probe(output)
    Dir.mktmpdir('woods-impact-trace') do |directory|
      path = File.join(directory, 'probe.rb')
      write_probe(path)
      load path
      units = Woods::RubyAnalyzer.analyze(paths: [path])
      caller = units.find { |unit| unit.identifier == 'WoodsImpactProbe::Caller#run' }
      static = caller.dependencies.dup
      traces = Woods::RubyAnalyzer::TraceEnricher.record do
        WoodsImpactProbe::Caller.new.run(WoodsImpactProbe::Callee.new)
      end
      Woods::RubyAnalyzer::TraceEnricher.merge(units: units, trace_data: traces)
      callee = units.find { |unit| unit.identifier == 'WoodsImpactProbe::Callee#run' }
      result = { static_dependencies: static, observed: callee.metadata[:trace],
                 dependencies_after_merge: caller.dependencies }
      write(output, 'trace_probe', result)
      verify_trace(result)
      result
    end
  end

  def self.write_probe(path)
    File.write(path, <<~SOURCE)
      module WoodsImpactProbe
        class Callee
          def run
            :ok
          end
        end
        class Caller
          def run(collaborator)
            collaborator.run
          end
        end
      end
    SOURCE
  end

  def self.verify_trace(result)
    raise 'Probe unexpectedly has a static dependency' unless result[:static_dependencies].empty?
    unless result[:observed][:callers].any? { |item| item['caller_class'] == 'WoodsImpactProbe::Caller' }
      raise 'Trace did not recover the injected caller'
    end
    return if result[:dependencies_after_merge] == result[:static_dependencies]

    raise 'Trace merge unexpectedly changed graph dependencies'
  end

  def self.run(output)
    FileUtils.mkdir_p(output)
    index_dir = File.join(output, 'index')
    mapping = Woods::GemMapper.new(root: ROOT, output_dir: index_dir).map!
    measurements = CASES.to_h do |name, (identifier, type)|
      [name, measure(output, name, { 'identifier' => identifier, 'type' => type })]
    end
    Woods::PublishedIndex.open(index_dir) do |index|
      affected = Woods::GemMapAffectedSpecs.new(index).for(['lib/woods/gem_mapper.rb'])
      write(output, 'affected_specs', affected)
      raise 'Known mapper spec missing' unless affected[:specs].include?('spec/gem_mapper_spec.rb')
      raise 'Missing mapper witness' unless measurements.fetch('mapper').fetch(:spec_witnesses).positive?

      write(output, 'summary', { mapping: mapping, provenance: index.manifest['provenance'],
                                 measurements: measurements, affected_specs: affected, trace: trace_probe(output) })
    end
    puts JSON.pretty_generate(measurements)
  end
end

if $PROGRAM_NAME == __FILE__
  abort 'Pass a disposable output directory outside the checkout' unless ARGV.size == 1
  output = File.expand_path(ARGV.first)
  if output == SelfMapImpactSpike::ROOT || output.start_with?("#{SelfMapImpactSpike::ROOT}/")
    abort 'Output must be outside the checkout'
  end
  SelfMapImpactSpike.run(output)
end
