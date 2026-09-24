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

  it 'uses the actual published pretty JSON size for the reader and writer limit' do
    bytes = JSON.pretty_generate(build.data).bytesize
    stub_const('Woods::SourceInputs::Manifest::MAX_BYTES', bytes)
    expect(Woods::SourceInputs::Manifest.parse(JSON.pretty_generate(build.data)).data).to eq(build.data)
    stub_const('Woods::SourceInputs::Manifest::MAX_BYTES', bytes - 1)
    expect { build }.to raise_error(Woods::SourceInputs::Manifest::Invalid, /source_manifest_too_large/)
  end

  it 'refuses an oversized private handoff before starting the Rails child' do
    stub_const('Woods::SourceInputs::Manifest::MAX_BYTES', 100)
    expect(Process).not_to receive(:spawn)
    expect do
      expect(Woods::SourceInputs::Launcher.run(['--root', @root, '--output', @output, 'full'])).to eq(1)
    end.to output(/source capture exceeds .* narrow .*source roots/).to_stderr
  end
end
