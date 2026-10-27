# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'woods/source_inputs/session'
require 'woods/source_inputs/verifier'

RSpec.describe 'Skipped extractor source provenance' do
  let(:path) { 'app/models/concerns/archivable.rb' }

  around do |example|
    Dir.mktmpdir('woods-skipped-consumer') do |root|
      @root = root
      @output = File.join(root, 'index')
      @baseline_path = File.join(@output, 'source_inputs.json')
      @key = Woods::SourceInputs::PrivateKey.new(output_dir: @output, create: true)
      original_handoff = ENV.delete(Woods::SourceInputs::Handoff::ENV_KEY)
      example.run
    ensure
      ENV[Woods::SourceInputs::Handoff::ENV_KEY] = original_handoff
    end
  end

  def write_concern(value)
    target = File.join(@root, path)
    FileUtils.mkdir_p(File.dirname(target))
    File.write(target, "module Archivable\n  def archive_label; :#{value}; end\nend\n")
  end

  def session(operation)
    capture = Woods::SourceInputs::Scanner.new(root: @root, output_dir: @output, key: @key).call
    allow(Woods::SourceInputs::Handoff).to receive(:read).and_return(capture)
    Woods::SourceInputs::Session.new(root: @root, output_dir: @output,
                                     baseline_path: @baseline_path, operation: operation)
  end

  def baseline
    write_concern('before')
    run = session('full')
    run.consume_unit(:models, path)
    manifest = run.finish(generation: 1, eager_load_complete: true)
    File.write(@baseline_path, JSON.generate(manifest.data))
    manifest
  end

  it 'retains a skipped table scope after model and concern consumers read the changed file' do
    previous = baseline
    write_concern('after')
    run = session('incremental')
    expect(run.read_source(path).fetch('source')).to include(':after')
    run.consume_file(:concerns, path)
    run.consume_unit(:models, path)
    manifest = run.finish(generation: 2, eager_load_complete: true)

    expect(manifest.expanded.fetch('whole:database_tables').fetch(path))
      .to eq(previous.expanded.fetch('whole:database_tables').fetch(path))
    expect(manifest.expanded.fetch('file:concerns').fetch(path)).to eq(run.source_identity(path))
    expect(manifest.expanded.fetch('unit:models').fetch(path)).to eq(run.source_identity(path))
    expect(run.source_identity(path)).not_to eq(previous.expanded.fetch('whole:database_tables').fetch(path))
    result = Woods::SourceInputs::Verifier.new(manifest: manifest, output_dir: @output).call
    expect(result.fetch('state')).to eq('drifted')
    expect(result.fetch('changes').fetch('changed')).to include(path)
  end

  it 'advances the table scope when that family successfully runs, including an empty result' do
    previous = baseline
    write_concern('after')
    run = session('incremental')
    run.consume_extractor(:database_tables, [])
    manifest = run.finish(generation: 2, eager_load_complete: true)

    expect(manifest.expanded.fetch('whole:database_tables').fetch(path)).to eq(run.source_identity(path))
    expect(run.source_identity(path)).not_to eq(previous.expanded.fetch('whole:database_tables').fetch(path))
  end
end
