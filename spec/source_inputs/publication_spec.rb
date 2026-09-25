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

  it 'publishes the code generation with explicit unavailable evidence above the source manifest limit' do
    prepare.send(:publish_generation, 'full')
    generation = Woods::Generation.new(output_dir: @output)
    previous = generation.current
    extractor = prepare
    session = extractor.instance_variable_get(:@source_inputs)
    session.instance_variable_get(:@snapshot)['metrics']['padding'] = 'x' * 4000
    stub_const('Woods::SourceInputs::Manifest::MAX_BYTES', 2000)

    expect { extractor.send(:publish_generation, 'full') }
      .to output(/source_manifest_too_large.*bytes.*2000/).to_stderr
    expect { extractor.raise_on_publication_failure! }.not_to raise_error
    expect(generation.current.number).to eq(previous.number + 1)
    expect(published_manifest.data['state']).to eq('unavailable')
    status = Woods::SourceInputs::Status.new(output_dir: @output).call
    expect(status).to include('state' => 'unavailable', 'complete' => false)
    expect(status['recommendations']).not_to include('fresh_capture')
  end

  it 'writes exactly the pretty JSON bytes checked against the publication limit, with no appended newline' do
    prepare.send(:publish_generation, 'full')
    payload = Woods::Generation.new(output_dir: @output).payload_dir
    bytes = File.binread(File.join(payload, 'source_inputs.json'))

    expect(bytes).to eq(JSON.pretty_generate(published_manifest.data))
    expect(bytes).not_to end_with("\n")
    expect(bytes.bytesize).to be <= Woods::SourceInputs::Manifest::MAX_BYTES
  end

  it 'retains publication refusal after unit diagnostics have filled their path budget' do
    prepare.send(:publish_generation, 'full')
    generation = Woods::Generation.new(output_dir: @output)
    previous = generation.current
    extractor = prepare
    extractor.instance_variable_set(:@source_reference_paths, Set.new([@source]))
    session = extractor.instance_variable_get(:@source_inputs)
    FileUtils.mkdir_p(File.join(@root, 'custom_loader'))
    40.times do |index|
      path = File.join(@root, 'custom_loader', "unit_#{index}.rb")
      File.write(path, 'uncaptured input')
      session.consume_unit(:custom, path)
    end
    File.write(@source, 'changed after capture')

    expect(extractor.send(:publish_generation, 'full')).to be_nil
    expect { extractor.raise_on_publication_failure! }
      .to raise_error(Woods::ExtractionError, /Source-reference source changed/)
    expect(generation.current.token).to eq(previous.token)
  end

  ["unrelated_\xFF", "app/services/invalid_\xFF.rb", "app/services/invalid_\n\xFF/nested.rb"].each do |relative|
    it "names the escaped path and retains the active generation for #{relative.b.inspect}" do
      prepare.send(:publish_generation, 'full')
      generation = Woods::Generation.new(output_dir: @output)
      previous = generation.current
      path = File.join(@root.b, relative.b)
      FileUtils.mkdir_p(File.dirname(path))
      File.binwrite(path, 'private fixture contents never belong in a diagnostic')
      extractor = prepare
      extractor.instance_variable_set(:@source_reference_paths, Set.new([@source]))

      expect(extractor.send(:publish_generation, 'full')).to be_nil
      expect { extractor.raise_on_publication_failure! }.to raise_error(Woods::ExtractionError) { |error|
        expect(error.message).to include('undecodable_source_path', '\\xFF', relative.b.split('_').first)
        expect(error.message).not_to include("\n", 'private fixture contents')
        expect(error.message).to be_ascii_only
      }
      expect(generation.current.token).to eq(previous.token)
      expect(Woods::SourceInputs::Status.new(output_dir: @output, mode: 'deep').call['state']).to eq('unknown')
    end
  end
end
