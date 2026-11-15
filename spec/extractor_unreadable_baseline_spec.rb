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

  # Extractors a run can complete with: a whole-app rake_tasks family a
  # changed rake file triggers, so a run that is not refused publishes.
  def stub_runnable_extractors
    require 'active_support'
    require 'active_support/isolated_execution_state'
    require 'active_support/core_ext/time'
    require 'active_support/core_ext/string/inflections'
    Woods.configuration.concurrent_extraction = false
    allow(Time).to receive(:current).and_return(Time.now)
    allow(Rails).to receive(:version).and_return('8.0.0')
    allow(extractor).to receive_messages(git_available?: false)
    stub_const('Woods::Extractor::EXTRACTORS',
               { models: extractor_returning(:model, 'Lantern', 'app/models/lantern.rb'),
                 rake_tasks: extractor_returning(:rake_task, 'lantern:light', 'lib/tasks/lantern.rake'),
                 rails_source: Class.new { define_method(:extract_all) { [] } } })
  end

  def extractor_returning(type, identifier, file_path)
    unit = Woods::ExtractedUnit.new(type: type, identifier: identifier, file_path: file_path)
    unit.source_code = 'Lantern'
    Class.new { define_method(:extract_all) { [unit] } }
  end

  def changed_rake_file
    path = @root.join('lib/tasks/lantern.rake')
    path.dirname.mkpath
    path.write('task :light')
    [path.to_s]
  end

  describe 'a flat generation with no dependency_graph.json' do
    before do
      stub_runnable_extractors
      # The real source-reference preparation: over an empty graph it opens
      # an empty baseline rather than refusing, so it does not stop the run.
      allow(extractor).to receive(:prepare_source_reference_baseline).and_call_original
    end

    let(:no_flat_graph) { /Generation 1 under #{Regexp.escape(output.to_s)}.*dependency_graph\.json.*woods:extract/ }

    def publish_flat_generation(payload: nil)
      output.mkpath
      Woods::Generation.new(output_dir: output).bump!(reason: 'full', payload: payload)
    end

    it 'refuses extract_changed and leaves the index exactly as it was' do
      publish_flat_generation
      paths = changed_rake_file

      expect_refusal(no_flat_graph) { extractor.extract_changed(paths) }
      expect(Woods::Generation.new(output_dir: output).current.number).to eq(1)
    end

    it 'refuses refresh and leaves the index exactly as it was' do
      publish_flat_generation

      expect_refusal(no_flat_graph) { extractor.refresh(:rake_tasks) }
      expect(Woods::Generation.new(output_dir: output).current.number).to eq(1)
    end

    # Woods never writes an empty pointer. Seeding resolves it to the output
    # root itself, and the strict payload open refuses after the source-input
    # key is written, so only the published state is pinned here.
    it 'refuses a marker whose payload pointer is empty and publishes nothing' do
      marker = publish_flat_generation(payload: '')
      marker_bytes = output.join(Woods::Generation::FILENAME).binread
      paths = changed_rake_file

      expect { extractor.extract_changed(paths) }
        .to raise_error(Woods::ExtractionError, /payload directory.*woods:extract/)
      expect { extractor.refresh(:rake_tasks) }
        .to raise_error(Woods::ExtractionError, /payload directory.*woods:extract/)

      expect(output.join(Woods::Generation::FILENAME).binread).to eq(marker_bytes)
      expect(Woods::Generation.new(output_dir: output).current.number).to eq(marker.number)
      expect(Dir.children(output.join('payloads'))).to be_empty
    end
  end

  # An in-memory graph stands in for a graph file only before anything is
  # published. Once a generation is published, a graph held in memory may
  # predate it, so a published generation without its graph file refuses.
  describe 'a published generation without its graph file, while a graph is held in memory' do
    before do
      stub_runnable_extractors
      allow(extractor).to receive(:prepare_source_reference_baseline).and_call_original
    end

    let(:payload_without_graph) do
      /#{Regexp.escape(output.join(payload_name).to_s)}.*dependency_graph\.json.*woods:extract/
    end
    let(:flat_without_graph) do
      /Generation 1 under #{Regexp.escape(output.to_s)}.*dependency_graph\.json.*woods:extract/
    end

    def publish_flat_generation
      output.mkpath
      Woods::Generation.new(output_dir: output).bump!(reason: 'full')
    end

    it 'refuses extract_changed over a payload without its graph' do
      publish_generation(graph: false)
      hold_graph_in_memory
      paths = changed_rake_file

      expect_refusal(payload_without_graph) { extractor.extract_changed(paths) }
    end

    it 'refuses refresh over a payload without its graph' do
      publish_generation(graph: false)
      hold_graph_in_memory

      expect_refusal(payload_without_graph) { extractor.refresh(:rake_tasks) }
    end

    it 'refuses extract_changed over a flat generation without its graph' do
      publish_flat_generation
      hold_graph_in_memory
      paths = changed_rake_file

      expect_refusal(flat_without_graph) { extractor.extract_changed(paths) }
    end

    it 'refuses refresh over a flat generation without its graph' do
      publish_flat_generation
      hold_graph_in_memory

      expect_refusal(flat_without_graph) { extractor.refresh(:rake_tasks) }
    end

    it 'refuses a reused extractor whose graph predates the generation published since' do
      extractor.extract_all
      other = Woods::Extractor.new(output_dir: output)
      allow(other).to receive_messages(safe_eager_load!: nil, git_available?: false)
      lantern, beacon = %w[Lantern Beacon].map do |name|
        Woods::ExtractedUnit.new(type: :model, identifier: name, file_path: "app/models/#{name.downcase}.rb")
                            .tap { |unit| unit.source_code = name }
      end
      models = Class.new { define_method(:extract_all) { [lantern, beacon] } }
      stub_const('Woods::Extractor::EXTRACTORS', Woods::Extractor::EXTRACTORS.merge(models: models))
      other.extract_all
      published = Woods::Generation.new(output_dir: output).current
      published_graph = output.join(published.payload, 'dependency_graph.json')
      expect(published_graph.read).to include('Beacon')
      published_graph.delete
      paths = changed_rake_file

      expect(extractor.dependency_graph.node('Lantern', type: :model)).not_to be_nil
      expect_refusal(/#{Regexp.escape(output.join(published.payload).to_s)}.*dependency_graph\.json/) do
        extractor.extract_changed(paths)
      end
      expect(Woods::Generation.new(output_dir: output).current.number).to eq(published.number)
    end
  end

  describe 'recovery after a refusal' do
    before { stub_runnable_extractors }

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
