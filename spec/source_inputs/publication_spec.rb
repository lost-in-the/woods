# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'woods/extractor'
require 'woods/source_inputs/status'

RSpec.describe 'Source provenance publication' do
  around do |example|
    Dir.mktmpdir('woods-source-publication') do |root|
      @root = root
      @output = File.join(root, 'index')
      @source = File.join(root, 'app/services/pay.rb')
      FileUtils.mkdir_p(File.dirname(@source))
      File.write(@source, 'before')
      @key = Woods::SourceInputs::PrivateKey.new(output_dir: @output, create: true)
      example.run
    end
  end

  before do
    stub_const('Rails', double('Rails', root: Pathname.new(@root), logger: double('Logger').as_null_object))
  end

  def prepare(operation = 'full')
    capture = Woods::SourceInputs::Scanner.new(root: @root, output_dir: @output, key: @key).call
    allow(Woods::SourceInputs::Handoff).to receive(:read).and_return(capture)
    extractor = Woods::Extractor.new(output_dir: @output)
    extractor.send(:begin_source_inputs, operation)
    extractor.send(:begin_payload!)
    extractor.instance_variable_set(:@eager_load_complete, true)
    extractor
  end

  def published_manifest
    payload = Woods::Generation.new(output_dir: @output).payload_dir
    Woods::SourceInputs::Manifest.parse(File.read(File.join(payload, 'source_inputs.json')))
  end

  it 'never reads an escaping or symlinked provenance baseline' do
    FileUtils.mkdir_p(File.join(@root, 'outside'))
    File.symlink(File.join(@root, 'outside'), File.join(@output, 'escaped'))
    extractor = Woods::Extractor.new(output_dir: @output)
    ['../outside', 'escaped'].each do |payload|
      File.write(File.join(@output, 'generation.json'), JSON.generate(number: 1, payload: payload))
      expect(extractor.send(:source_input_baseline_path)).to be_nil
    end
  end

  it 'retains a failed partial consumer baseline while another consumer advances the same path' do
    prepare.send(:publish_generation, 'full')
    previous = published_manifest
    File.write(@source, 'after')
    extractor = prepare('refresh')
    services = Object.new
    Woods::SourceInputs::ConsumerErrors.record(services)
    run = extractor.instance_variable_get(:@source_inputs)
    expect(extractor.send(:source_consumer_failed?, :services, services)).to be(true)
    run.consume_extractor(:events, [])
    extractor.send(:publish_generation, 'refresh')
    current = published_manifest
    expect(current.expanded['file:services']).to eq(previous.expanded['file:services'])
    expect(current.expanded['whole:events']).not_to eq(previous.expanded['whole:events'])
    expect(current.data['unverified_scopes']).to include('extractor:services')
    expect(current.data['unverified_scopes']).not_to include('extractor:events')
  end

  it 'keeps the prior source artifact and generation when candidate publication fails' do
    prepare.send(:publish_generation, 'full')
    generation = Woods::Generation.new(output_dir: @output)
    previous = generation.current
    source_path = File.join(generation.payload_dir, 'source_inputs.json')
    bytes = File.binread(source_path)
    File.write(@source, 'after')
    extractor = prepare
    allow(extractor).to receive(:sync_payload).and_raise(IOError, 'fixture sync failed')
    expect(extractor.send(:publish_generation, 'full')).to be_nil
    expect { extractor.raise_on_publication_failure! }.to raise_error(Woods::ExtractionError)
    expect(generation.current.token).to eq(previous.token)
    expect(File.binread(source_path)).to eq(bytes)
    expect(Woods::SourceInputs::Status.new(output_dir: @output).call['state']).to eq('drifted')
  end

  it 'does not advance captured source on a no-op incremental run' do
    prepare.send(:publish_generation, 'full')
    generation = Woods::Generation.new(output_dir: @output)
    previous = generation.current
    source_path = File.join(generation.payload_dir, 'source_inputs.json')
    bytes = File.binread(source_path)
    File.write(@source, 'omitted dirty input')
    extractor = prepare('incremental')
    allow(extractor).to receive(:write_dependency_graph)
    extractor.send(:finalize_incremental_run, Set.new)
    expect(generation.current.token).to eq(previous.token)
    expect(File.binread(source_path)).to eq(bytes)
  end

  it 'retains the active generation when an undecodable path prevents reference verification' do
    prepare.send(:publish_generation, 'full')
    generation = Woods::Generation.new(output_dir: @output)
    previous = generation.current
    File.binwrite(File.join(@root.b, 'unrelated_'.b + "\xFF".b), 'input')
    extractor = prepare
    extractor.instance_variable_set(:@source_reference_paths, Set.new([@source]))

    expect(extractor.send(:publish_generation, 'full')).to be_nil
    expect { extractor.raise_on_publication_failure! }.to raise_error(Woods::ExtractionError)
    expect(generation.current.token).to eq(previous.token)
    expect(Woods::SourceInputs::Status.new(output_dir: @output, mode: 'deep').call['state']).to eq('unknown')
  end
end
