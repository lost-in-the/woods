# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'json'
require 'woods/dependency_graph'
require 'woods/flow_precomputer'
require 'woods/resilience/index_validator'

# #967: a single-segment call target that suffix-matches one app unit, while
# the booted precompute finds a top-level constant of that name, is reported
# as ambiguous. The verdicts are decided once, in the booted process, and
# published with the flows, so an assembler without Rails (trace_flow's live
# rebuild) reaches the same answer.
#
# Truth table for one unrooted single-segment target with exactly one suffix
# match (every other shape resolves as before):
#
#   | verdicts available | name is a top-level constant | result                        |
#   |--------------------|------------------------------|-------------------------------|
#   | yes                | yes                          | ambiguous, ::Name + app unit  |
#   | yes                | no                           | the app unit (as before)      |
#   | no (unknown)       | -                            | the app unit (as before)      |
RSpec.describe 'Flow top-level constant verdicts' do
  let(:output_dir) { Dir.mktmpdir('flow_top_level_constants') }
  let(:graph) { Woods::DependencyGraph.new }
  let(:verdicts_path) { File.join(output_dir, Woods::FlowAssembler::TOP_LEVEL_CONSTANTS_PATH) }

  after { FileUtils.remove_entry(output_dir) }

  def make_unit(type:, identifier:, source_code:, metadata: {})
    unit = Woods::ExtractedUnit.new(type: type, identifier: identifier,
                                    file_path: "app/#{type}s/#{identifier.downcase}.rb")
    unit.metadata = metadata
    unit.source_code = source_code
    unit
  end

  def publish(unit)
    type_dir = File.join(output_dir, "#{unit.type}s")
    FileUtils.mkdir_p(type_dir)
    filename = "#{unit.identifier.gsub('::', '__').gsub(/[^a-zA-Z0-9_-]/, '_')}.json"
    File.write(File.join(type_dir, filename), JSON.generate(unit.to_h))
    graph.register(unit)
    unit
  end

  let!(:app_unit) do
    publish(make_unit(type: :service, identifier: 'Lint::ShadowProbe', source_code: <<~RUBY))
      module Lint
        class ShadowProbe
          def self.t(*)
            self
          end
        end
      end
    RUBY
  end

  let(:controller_source) do
    <<~RUBY
      class GreetingsController < ApplicationController
        def show
          ShadowProbe.t(:hello)
        end
      end
    RUBY
  end

  let!(:controller) do
    publish(make_unit(type: :controller, identifier: 'GreetingsController', metadata: { actions: %w[show] },
                      source_code: controller_source))
  end

  def call_operation(flow)
    flow = flow.to_h
    flow[:steps].first[:operations].find { |op| op[:type] == :call && op[:target] == 'ShadowProbe' }
  end

  describe '.top_level_constants' do
    let(:namespace) { Module.new }

    it 'keeps a defined name, drops a missing one, and never loads a pending autoload' do
      namespace.const_set(:Defined, Module.new)
      sentinel = File.join(output_dir, 'loaded')
      autoload_file = File.join(output_dir, 'pending.rb')
      File.write(autoload_file, "File.write(#{sentinel.dump}, 'loaded')\nPending = 1\n")
      namespace.autoload(:Pending, autoload_file)

      verdicts = Woods::FlowAssembler.top_level_constants(%w[Pending Missing Defined], namespace: namespace)

      expect(verdicts).to eq(['Defined'])
      expect(File.exist?(sentinel)).to be(false)
    end

    it 'considers only single-segment constant names' do
      namespace.const_set(:Defined, Module.new)

      verdicts = Woods::FlowAssembler.top_level_constants(['defined', 'Defined::Inner', 'Defined', 'Defined'],
                                                          namespace: namespace)

      expect(verdicts).to eq(['Defined'])
    end
  end

  describe 'a booted precompute' do
    it 'publishes the verdict and marks the step ambiguous with both candidates' do
      stub_const('ShadowProbe', Module.new)

      Woods::FlowPrecomputer.new(units: [controller], graph: graph, output_dir: output_dir).precompute

      expect(JSON.parse(File.read(verdicts_path))).to eq('top_level_constants' => ['ShadowProbe'])
      document = JSON.parse(File.read(File.join(output_dir, 'flows', 'GreetingsController_show.json')))
      operation = document['steps'].first['operations'].find { |op| op['target'] == 'ShadowProbe' }
      expect(operation['ambiguous_candidates']).to eq(['::ShadowProbe', 'Lint::ShadowProbe'])
      expect(document['steps'].map { |step| step['unit'] }).to eq(['GreetingsController#show'])
    end

    it 'decides from this run, not from verdicts a previous generation published' do
      FileUtils.mkdir_p(File.dirname(verdicts_path))
      File.write(verdicts_path, JSON.generate('top_level_constants' => ['ShadowProbe']))

      Woods::FlowPrecomputer.new(units: [controller], graph: graph, output_dir: output_dir).precompute

      expect(JSON.parse(File.read(verdicts_path))).to eq('top_level_constants' => [])
      document = JSON.parse(File.read(File.join(output_dir, 'flows', 'GreetingsController_show.json')))
      expect(document['steps'].map { |step| step['unit'] }).to eq(['GreetingsController#show', 'Lint::ShadowProbe'])
    end

    it 'publishes the same verdicts from an incremental delta as from a full run' do
      stub_const('ShadowProbe', Module.new)
      Woods::FlowPrecomputer.new(units: [controller], graph: graph, output_dir: output_dir).precompute
      full = File.read(verdicts_path)
      File.delete(verdicts_path)

      Woods::FlowPrecomputer.new(units: [controller], graph: graph, output_dir: output_dir)
                            .recompute_delta(touched_units: [])

      expect(File.read(verdicts_path)).to eq(full)
    end
  end

  describe 'an assembler without Rails, as trace_flow builds one' do
    def live_flow
      assembler = Woods::FlowAssembler.new(graph: graph, extracted_dir: output_dir)
      assembler.assemble('GreetingsController#show', max_depth: 3)
    end

    it 'reaches the precomputed answer from the published verdicts alone' do
      stub_const('ShadowProbe', Module.new)
      Woods::FlowPrecomputer.new(units: [controller], graph: graph, output_dir: output_dir).precompute
      precomputed = JSON.parse(File.read(File.join(output_dir, 'flows', 'GreetingsController_show.json')))
      hide_const('ShadowProbe')

      live = JSON.parse(JSON.generate(live_flow.to_h))

      expect(live.except('generated_at')).to eq(precomputed.except('generated_at'))
      operation = live['steps'].first['operations'].find { |op| op['target'] == 'ShadowProbe' }
      expect(operation['ambiguous_candidates']).to eq(['::ShadowProbe', 'Lint::ShadowProbe'])
    end

    it 'resolves the app unit as before when the index published no verdicts (unknown)' do
      stub_const('ShadowProbe', Module.new)

      flow = live_flow

      expect(File.exist?(verdicts_path)).to be(false)
      expect(call_operation(flow)).not_to have_key(:ambiguous_candidates)
      expect(flow.to_h[:steps].map { |step| step[:unit] }).to eq(['GreetingsController#show', 'Lint::ShadowProbe'])
    end

    it 'resolves the app unit as before when the published verdicts do not name it (near miss)' do
      FileUtils.mkdir_p(File.dirname(verdicts_path))
      File.write(verdicts_path, JSON.generate('top_level_constants' => ['OtherName']))

      expect(call_operation(live_flow)).not_to have_key(:ambiguous_candidates)
    end

    it 'refuses a malformed verdicts artifact instead of resolving as if there were none' do
      FileUtils.mkdir_p(File.dirname(verdicts_path))
      File.write(verdicts_path, JSON.generate(['ShadowProbe']))

      expect { live_flow }.to raise_error(JSON::ParserError, /top_level_constants/)
    end
  end

  describe 'resolver memo' do
    before do
      publish(make_unit(type: :service, identifier: 'Billing::Refund', source_code: <<~RUBY))
        module Billing
          class Refund
          end
        end
      RUBY
    end

    def resolutions(*targets)
      assembler = Woods::FlowAssembler.new(graph: graph, extracted_dir: output_dir, top_level_constants: [])
      targets.map { |target| assembler.send(:resolve_target, target) }
    end

    it 'keeps the rooted flag in the key, in either order' do
      expect(resolutions('::Refund', 'Refund', 'Refund.new')).to eq([nil, 'Billing::Refund', 'Billing::Refund'])
      expect(resolutions('Refund', '::Refund', '::Refund.new')).to eq(['Billing::Refund', nil, nil])
    end
  end

  describe 'index validation' do
    before do
      FileUtils.mkdir_p(File.join(output_dir, 'flows'))
      File.write(File.join(output_dir, 'flows', 'flow_index.json'), '{}')
    end

    it 'accepts well-formed verdicts and reports malformed ones' do
      File.write(verdicts_path, JSON.generate('top_level_constants' => ['ShadowProbe']))
      expect(Woods::Resilience::IndexValidator.new(index_dir: output_dir).validate.errors)
        .not_to include(a_string_matching(/top_level_constants/))

      File.write(verdicts_path, JSON.generate(['ShadowProbe']))
      expect(Woods::Resilience::IndexValidator.new(index_dir: output_dir).validate.errors)
        .to include(a_string_matching(%r{flows/top_level_constants\.json: expected}))
    end
  end
end
