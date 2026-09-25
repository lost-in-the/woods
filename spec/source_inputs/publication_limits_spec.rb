# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'woods/source_inputs/session'
require 'woods/source_inputs/launcher'

RSpec.describe 'Source evidence serialization budgets' do
  around do |example|
    Dir.mktmpdir('woods-evidence-budget') do |root|
      @root = root
      @output = File.join(root, 'index')
      @key = Woods::SourceInputs::PrivateKey.new(output_dir: @output, create: true)
      @snapshot = Woods::SourceInputs::Scanner.new(root: root, output_dir: @output, key: @key).call
      example.run
    end
  end

  def build
    Woods::SourceInputs::Manifest.build(snapshot: @snapshot, scopes: {}, boot_verified: true, generation: 1)
  end

  it 'bounds oversized freshness evidence without refusing code publication' do
    @snapshot['metrics']['padding'] = 'x' * 4000
    stub_const('Woods::SourceInputs::Manifest::MAX_BYTES', 2000)

    manifest = build

    expect(manifest.data).to include('state' => 'unavailable', 'complete' => false, 'comparison_complete' => false)
    expect(manifest.data['unavailable']).to include('reason' => 'source_manifest_too_large', 'limit_bytes' => 2000)
    expect(manifest.data['unavailable']['size_bytes']).to be > 4000
    expect(JSON.pretty_generate(manifest.data).bytesize).to be <= 2000
    expect(Woods::SourceInputs::Manifest.parse(JSON.pretty_generate(manifest.data)).data).to eq(manifest.data)
  end

  it 'refuses malformed unavailable evidence instead of treating it as an exemption' do
    @snapshot['metrics']['padding'] = 'x' * 4000
    stub_const('Woods::SourceInputs::Manifest::MAX_BYTES', 2000)
    data = build.data
    [{ 'complete' => true }, { 'state' => 'current' }, { 'reference_cache_sha256' => 'invalid' },
     { 'unavailable' => { 'reason' => 'other_failure', 'size_bytes' => 4000, 'limit_bytes' => 2000 } }].each do |change|
      expect { Woods::SourceInputs::Manifest.new(data.merge(change)) }
        .to raise_error(Woods::SourceInputs::Manifest::Invalid, /invalid_unavailable_source_manifest/)
    end
  end

  it 'continues a fresh child with an explicit unavailable marker when private capture exceeds the limit' do
    stub_const('Woods::SourceInputs::Manifest::MAX_BYTES', 100)
    script = "record = JSON.parse(ENV.fetch('WOODS_SOURCE_CAPTURE')); " \
             "exit(record.dig('unavailable', 'reason') == 'source_manifest_too_large' && !record.key?('path') ? 0 : 1)"
    expect do
      result = Woods::SourceInputs::Launcher.run(['--root', @root, '--output', @output, 'full'],
                                                 command: [RbConfig.ruby, '-rjson', '-e', script])
      expect(result).to eq(0)
    end.to output(/source_manifest_too_large.*bytes.*limit 100/).to_stderr
  end
end
