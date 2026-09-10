# frozen_string_literal: true

require 'spec_helper'
require 'pathname'
require 'tmpdir'
require 'fileutils'
require 'woods'
require 'woods/extractor'
require 'woods/flow_precomputer'
require 'active_support'
require 'active_support/core_ext/time/calculations'

# The durability model this gem publishes under.
#
# Readers resolve only through `generation.json`, so no payload file has a
# reader until the pointer names it. Per-file fsync on those files buys
# nothing and costs 8.9ms each on btrfs — 8323 units is over a minute of
# forced flushes. The guarantee that replaces it: when the pointer is durable,
# every file in the payload it names is durable, because one filesystem flush
# runs before the pointer write.
RSpec.describe 'payload durability' do
  let(:tmpdir) { Dir.mktmpdir('woods_durability') }
  let(:rails_root) { Pathname.new(tmpdir) }
  let(:output_dir) { File.join(tmpdir, 'output') }
  let(:extractor) { Woods::Extractor.new(output_dir: output_dir) }

  # Every AtomicFile.write this example makes, as { path:, durable: }.
  let(:writes) { [] }
  # The same writes plus the payload flush, in the order they happened.
  let(:events) { [] }

  before do
    stub_const('Rails', double('Rails'))
    allow(Rails).to receive(:root).and_return(rails_root)
    allow(Rails).to receive(:logger).and_return(double('Logger').as_null_object)
    allow(Rails).to receive(:version).and_return('8.0.0')
    @original_config = Woods.configuration
    Woods.configuration = Woods::Configuration.new
    allow(Woods::AtomicFile).to receive(:write).and_wrap_original do |original, path, content, **options|
      writes << { path: path.to_s, durable: options.fetch(:durable, true) }
      events << [:write, path.to_s]
      original.call(path, content, **options)
    end
  end

  after do
    Woods.configuration = @original_config
    FileUtils.rm_rf(tmpdir)
  end

  def unit(type, identifier)
    Woods::ExtractedUnit.new(
      type: type, identifier: identifier, file_path: "app/#{type}s/#{identifier.downcase}.rb"
    ).tap { |built| built.source_code = "class #{identifier}; end" }
  end

  def payload_writes
    root = extractor.send(:payload_dir).to_s
    writes.select { |write| write[:path].start_with?(root) }
  end

  describe 'the extractor payload writers' do
    before do
      extractor.send(:begin_payload!)
      models = [unit(:model, 'User'), unit(:model, 'Order')]
      models.each { |built| extractor.dependency_graph.register(built) }
      extractor.instance_variable_set(:@results, { model: models })
      FileUtils.mkdir_p(extractor.send(:payload_dir).join('model').to_s)
    end

    it 'writes every payload file without a per-file fsync' do
      extractor.send(:write_results)
      extractor.send(:write_dependency_graph)
      extractor.instance_variable_set(:@graph_analysis, { orphans: [] })
      extractor.send(:write_graph_analysis)
      extractor.send(:write_manifest)
      extractor.send(:write_structural_summary)
      extractor.send(:regenerate_type_index, :model)

      expect(payload_writes.length).to be >= 7
      expect(payload_writes.reject { |write| write[:durable] == false }).to be_empty
    end

    it 'forces no fsync at all on the payload while writing it' do
      fsyncs = 0
      allow_any_instance_of(Tempfile).to receive(:fsync) { fsyncs += 1 }
      allow(Woods::AtomicFile).to receive(:fsync_directory) { fsyncs += 1 }

      extractor.send(:write_results)
      extractor.send(:write_dependency_graph)

      expect(fsyncs).to eq(0)
    end
  end

  describe 'FlowPrecomputer' do
    it 'writes flow documents and the flow index without a per-file fsync' do
      graph = Woods::DependencyGraph.new
      controller = unit(:controller, 'OrdersController')
      controller.metadata = { actions: ['index'] }
      graph.register(controller)
      FileUtils.mkdir_p(File.join(output_dir, 'controllers'))

      Woods::FlowPrecomputer.new(units: [controller], graph: graph, output_dir: output_dir).precompute

      flow_writes = writes.select { |write| write[:path].include?('/flows/') }
      expect(flow_writes.length).to be >= 2
      expect(flow_writes.reject { |write| write[:durable] == false }).to be_empty
    end
  end

  # The guarantee that replaces per-file fsync. It is an ordering guarantee,
  # so ordering is what the spec pins.
  describe 'publishing a generation' do
    before do
      allow(Woods::AtomicFile).to receive(:sync_directory_tree) do |directory|
        events << [:sync, directory.to_s]
        :syncfs
      end
    end

    it 'flushes the payload directory before writing the pointer' do
      extractor.send(:begin_payload!)
      payload = extractor.send(:payload_dir).to_s

      extractor.send(:publish_generation, 'full')

      sync_at = events.index { |kind, _| kind == :sync }
      pointer_at = events.index { |kind, path| kind == :write && path.end_with?('generation.json') }
      expect(sync_at).not_to be_nil
      expect(pointer_at).not_to be_nil
      expect(sync_at).to be < pointer_at
      expect(events[sync_at][1]).to eq(payload)
    end

    it 'keeps generation.json itself durable' do
      extractor.send(:begin_payload!)
      extractor.send(:publish_generation, 'full')

      pointer = writes.find { |write| write[:path].end_with?('generation.json') }
      expect(pointer[:durable]).to be(true)
    end

    it 'flushes the flat output directory when the run built no payload' do
      FileUtils.mkdir_p(output_dir)

      extractor.send(:publish_generation, 'full')

      expect(events.find { |kind, _| kind == :sync }[1]).to eq(output_dir)
    end
  end

  # Files whose readers do not resolve through `generation.json` keep the
  # per-file fsync: nothing else ever makes them durable.
  describe 'writers outside the payload' do
    it 'keeps generation.json durable' do
      FileUtils.mkdir_p(output_dir)
      Woods::Generation.new(output_dir: output_dir).bump!(reason: 'full', payload: nil)

      pointer = writes.find { |write| write[:path].end_with?('generation.json') }
      expect(pointer[:durable]).to be(true)
    end

    it 'keeps the watch daemon status durable' do
      require 'woods/watch/status'
      status = Woods::Watch::Status.new(output_dir: output_dir)
      status.write(state: :running)

      expect(writes.find { |write| write[:path] == status.path }[:durable]).to be(true)
    end
  end
end
