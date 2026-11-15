# frozen_string_literal: true

require 'spec_helper'
require 'woods/extractor'

RSpec.describe 'Incremental runs over a baseline the published generation cannot provide' do
  include_context 'isolated Woods runtime'

  around do |example|
    Dir.mktmpdir('woods-unreadable-baseline') do |root|
      @root = Pathname.new(root)
      example.run
    end
  end

  before do
    require 'woods'
    stub_const('Rails', double('Rails', root: @root, logger: double('Logger').as_null_object))
    @original_config = Woods.configuration
    Woods.configuration = Woods::Configuration.new
    allow(extractor).to receive(:safe_eager_load!)
    allow(extractor).to receive(:prepare_source_reference_baseline)
  end

  after { Woods.configuration = @original_config }

  let(:output) { @root.join('index') }
  let(:extractor) { Woods::Extractor.new(output_dir: output) }
  let(:empty_graph) { JSON.generate(nodes: {}, edges: {}, reverse: {}, file_map: {}) }
  let(:payload_name) { Woods::PayloadStore.name_for(1) }

  def publish_generation(graph: true)
    directory = Woods::PayloadStore.new(output).create(1)
    directory.join('manifest.json').write(JSON.generate(woods_version: '2.0.0', total_units: 0, counts: {}))
    directory.join('dependency_graph.json').write(empty_graph) if graph
    Woods::Generation.new(output_dir: output).bump!(reason: 'full', payload: payload_name)
    directory
  end

  def publish_generation_then_lose_payload
    FileUtils.rm_rf(publish_generation)
  end

  def hold_graph_in_memory
    extractor.dependency_graph.register(
      Woods::ExtractedUnit.new(type: :model, identifier: 'Lantern', file_path: nil)
    )
  end

  def artifacts
    Dir.glob(output.join('**/*'), File::FNM_DOTMATCH).reject { |path| path.end_with?('/.') }.to_h do |path|
      [path.delete_prefix("#{output}/"), File.directory?(path) ? :directory : File.binread(path)]
    end
  end

  def expect_refusal(pattern, &run)
    previous = artifacts
    expect(&run).to raise_error(Woods::ExtractionError, pattern)
    expect(artifacts).to eq(previous)
  end

  let(:missing_payload) { /#{Regexp.escape(output.join(payload_name).to_s)}.*missing.*woods:extract/ }

  %w[incremental refresh].each do |operation|
    context "when the marker names a payload directory that is gone (#{operation})" do
      it 'refuses before anything is written' do
        publish_generation_then_lose_payload

        expect_refusal(missing_payload) { extractor.send(:prepare_incremental_run, operation: operation) }
      end

      it 'refuses rather than seed from a stale graph left in the flat root' do
        publish_generation_then_lose_payload
        output.join('dependency_graph.json').write(empty_graph)

        expect_refusal(missing_payload) { extractor.send(:prepare_incremental_run, operation: operation) }
      end

      it 'refuses even when the caller holds a populated graph in memory' do
        publish_generation_then_lose_payload
        hold_graph_in_memory

        expect_refusal(missing_payload) { extractor.send(:prepare_incremental_run, operation: operation) }
      end
    end

    context "when the payload directory exists without dependency_graph.json (#{operation})" do
      it 'refuses before anything is written' do
        publish_generation(graph: false)

        expect_refusal(/#{Regexp.escape(output.join(payload_name).to_s)}.*dependency_graph\.json.*woods:extract/) do
          extractor.send(:prepare_incremental_run, operation: operation)
        end
      end

      it 'proceeds when the caller holds a populated graph in memory' do
        publish_generation(graph: false)
        hold_graph_in_memory

        expect { extractor.send(:prepare_incremental_run, operation: operation) }.not_to raise_error
      end
    end
  end

  it 'refuses extract_changed and leaves the index exactly as it was' do
    publish_generation_then_lose_payload

    expect_refusal(missing_payload) { extractor.extract_changed([@root.join('app/models/lantern.rb').to_s]) }
    expect(Woods::Generation.new(output_dir: output).current.number).to eq(1)
  end

  it 'refuses refresh and leaves the index exactly as it was' do
    publish_generation_then_lose_payload

    expect_refusal(missing_payload) { extractor.refresh(:routes) }
    expect(Woods::Generation.new(output_dir: output).current.number).to eq(1)
  end

  it 'proceeds over a healthy payload generation' do
    publish_generation

    expect { extractor.send(:prepare_incremental_run) }.not_to raise_error
  end

  it 'proceeds over a flat generation whose graph sits in the output root' do
    output.mkpath
    output.join('dependency_graph.json').write(empty_graph)
    Woods::Generation.new(output_dir: output).bump!(reason: 'full')

    expect { extractor.send(:prepare_incremental_run) }.not_to raise_error
  end

  it 'proceeds with no published generation when the caller holds a populated graph in memory' do
    hold_graph_in_memory

    expect { extractor.send(:prepare_incremental_run) }.not_to raise_error
  end

  describe 'recovery after a refusal' do
    before do
      require 'active_support'
      require 'active_support/isolated_execution_state'
      require 'active_support/core_ext/time'
      require 'active_support/core_ext/string/inflections'
      Woods.configuration.concurrent_extraction = false
      allow(Time).to receive(:current).and_return(Time.now)
      allow(Rails).to receive(:version).and_return('8.0.0')
      allow(extractor).to receive_messages(git_available?: false)
      unit = Woods::ExtractedUnit.new(type: :model, identifier: 'Lantern', file_path: 'app/models/lantern.rb')
      unit.source_code = 'class Lantern; end'
      models = Class.new { define_method(:extract_all) { [unit] } }
      empty = Class.new { define_method(:extract_all) { [] } }
      stub_const('Woods::Extractor::EXTRACTORS', { models: models, rails_source: empty })
    end

    it 'refuses a second incremental run the same way, then a full extraction publishes a readable payload' do
      publish_generation_then_lose_payload
      changed = [@root.join('app/models/lantern.rb').to_s]

      expect_refusal(missing_payload) { extractor.extract_changed(changed) }
      expect_refusal(missing_payload) { extractor.extract_changed(changed) }

      extractor.extract_all

      marker = Woods::Generation.new(output_dir: output).current
      expect(marker.number).to eq(2)
      expect(output.join(marker.payload, 'dependency_graph.json')).to exist
      expect { extractor.send(:prepare_incremental_run) }.not_to raise_error
    end
  end
end
