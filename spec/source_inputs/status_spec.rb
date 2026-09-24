# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'rake'
require 'woods/source_inputs/status'

RSpec.describe Woods::SourceInputs::Status do
  around do |example|
    Dir.mktmpdir('woods-source-status') do |root|
      @root = root
      @output = File.join(root, 'index')
      @key = Woods::SourceInputs::PrivateKey.new(output_dir: @output, create: true)
      @payload = File.join(@output, 'payloads/00000001')
      FileUtils.mkdir_p(@payload)
      capture = Woods::SourceInputs::Scanner.new(root: root, output_dir: @output, key: @key).call
      manifest = Woods::SourceInputs::Manifest.build(snapshot: capture, scopes: {}, boot_verified: true, generation: 1)
      @manifest_path = File.join(@payload, 'source_inputs.json')
      File.write(@manifest_path, JSON.generate(manifest.data))
      example.run
    end
  end

  def status(**options)
    described_class.new(output_dir: @output, payload_dir: @payload, generation: 1, **options).call
  end

  it 'uses the supplied served payload and generation, even when the latest marker differs' do
    File.write(File.join(@output, 'generation.json'),
               JSON.generate(number: 2, token: 'new', payload: 'payloads/00000002'))
    expect(status).to include('state' => 'current', 'generation' => 1, 'check' => 'quick')
    expect(status(generation: 2)['reasons']).to eq(['generation_mismatch'])
    expect(status(mode: 'deep')['check']).to eq('deep')
  end

  it 'reports old, missing and malformed artifacts without creating or repairing them' do
    expect(described_class.new(output_dir: @output).call['state']).to eq('unknown')
    File.write(@manifest_path, '{}')
    expect(status['reasons']).to eq(['invalid_source_manifest'])
    File.unlink(@manifest_path)
    expect(status['reasons']).to eq(['source_manifest_unavailable'])
    File.mkfifo(@manifest_path)
    expect(status['reasons']).to eq(['invalid_source_manifest'])
  end

  it 'rejects escaping/symlink payloads and malformed markers before opening outside artifacts' do
    FileUtils.mkdir_p(File.join(@root, 'outside'))
    File.symlink(File.join(@root, 'outside'), File.join(@output, 'escaped'))
    allow(File).to receive(:open).and_call_original
    expect(File).not_to receive(:open).with(File.join(@root, 'outside', 'source_inputs.json'), anything)
    ['../outside', 'escaped'].each do |payload|
      File.write(File.join(@output, 'generation.json'), JSON.generate(number: 1, payload: payload))
      result = described_class.new(output_dir: @output).call
      expect(result['reasons']).to eq(['atomic_source_manifest_unavailable'])
    end
    %w[[] null 1].each do |json|
      File.write(File.join(@output, 'generation.json'), json)
      expect(described_class.new(output_dir: @output).call['reasons']).to eq(['invalid_generation'])
    end
  end

  it 'validates encoded option keys and values without shell path interpolation' do
    encoded = Base64.strict_encode64(JSON.generate(output: "#{@root}/a,b\nc", mode: 'deep'))
    expect(described_class.from_transport(encoded)['state']).to eq('unknown')
    ['invalid base64', Base64.strict_encode64(JSON.generate(secret: 'ignored')),
     Base64.strict_encode64(JSON.generate(output: 1)), 'x' * 20_000].each do |value|
      expect { described_class.from_transport(value) }.to raise_error(ArgumentError)
    end
    expect { status(mode: 'unbounded') }.to raise_error(ArgumentError)
  end

  it 'rejects undecodable explicit paths as configuration errors at construction' do
    %i[root output_dir payload_dir].each do |option|
      expect { status(**{ option => "bad_\xFF".b }) }
        .to raise_error(Woods::SourcePathEncoding::Invalid, 'source paths must contain valid UTF-8 bytes')
    end
  end

  it 'runs the task without invoking a Rails environment or provider' do
    old = Rake.application
    Rake.application = Rake::Application.new
    Rake::Task.define_task(:environment) { raise 'must not boot Rails' }
    load File.expand_path('../../lib/tasks/woods.rake', __dir__)
    task = Rake::Task['woods:source_status']
    expect(task.prerequisites).to be_empty
    encoded = Base64.strict_encode64(JSON.generate(output: @output))
    expect { task.invoke(encoded) }.to output(/"state":"unknown"/).to_stdout
  ensure
    Rake.application = old
  end
end
