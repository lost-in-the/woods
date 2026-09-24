# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'woods/source_inputs/session'
require 'woods/source_inputs/status'

RSpec.describe 'Source evidence boundaries' do
  around do |example|
    Dir.mktmpdir('woods-evidence') do |root|
      @root = root
      @output = File.join(root, 'index')
      @baseline = File.join(@output, 'baseline.json')
      @key = Woods::SourceInputs::PrivateKey.new(output_dir: @output, create: true)
      example.run
    end
  end

  def write(relative, content = 'source')
    path = File.join(@root, relative)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
    path
  end

  def snapshot
    Woods::SourceInputs::Scanner.new(root: @root, output_dir: @output, key: @key).call
  end

  def session(operation = 'full', capture: snapshot)
    allow(Woods::SourceInputs::Handoff).to receive(:read).and_return(capture)
    Woods::SourceInputs::Session.new(root: @root, output_dir: @output, baseline_path: @baseline,
                                     operation: operation)
  end

  def finish(run)
    run.finish(generation: 1, eager_load_complete: true)
  end

  def verify(manifest)
    Woods::SourceInputs::Verifier.new(manifest: manifest, output_dir: @output).call
  end

  %i[missing invalid wrong_key wrong_rules].each do |damage|
    it "keeps a #{damage} comparison baseline unknown without inventing additions" do
      write('app/services/pay.rb')
      data = finish(session).data
      data['key_id'] = '0' * 64 if damage == :wrong_key
      data['rules'] = '0' * 64 if damage == :wrong_rules
      File.write(@baseline, damage == :invalid ? '{}' : JSON.generate(data)) unless damage == :missing

      result = verify(finish(session('incremental')))

      expect(result).to include('state' => 'unknown', 'counts' => { 'added' => 0, 'changed' => 0, 'removed' => 0 })
      expect(result.fetch('reasons')).to include('missing_or_incompatible_source_baseline')
    end
  end

  it 'keeps legacy missing-baseline manifests conservative without the new optional field' do
    write('app/services/pay.rb')
    data = finish(session('incremental')).data
    data.delete('comparison_complete')

    result = verify(Woods::SourceInputs::Manifest.new(data))

    expect(result['state']).to eq('unknown')
    expect(result.dig('counts', 'added')).to eq(0)
  end

  it 'rejects malformed optional comparison coverage' do
    data = finish(session).data.merge('comparison_complete' => 'yes')

    expect { Woods::SourceInputs::Manifest.new(data) }.to raise_error(Woods::SourceInputs::Manifest::Invalid)
  end

  it 'does not call unvisited paths deleted when the final scan runs out of budget' do
    write('app/services/pay.rb')
    run = session
    partial = snapshot.merge('files' => {}, 'scope_paths' => {}, 'complete' => false,
                             'errors' => [{ 'reason' => 'scan_time_budget' }])
    allow(run).to receive(:scan).and_return(partial)

    manifest = finish(run)

    expect(manifest.data.fetch('errors')).to include('reason' => 'scan_time_budget')
    expect(manifest.data.fetch('errors')).not_to include(include('reason' => 'source_changed_during_extraction'))
    expect(verify(manifest)['state']).to eq('unknown')
  end

  it 'does not call previously unvisited paths additions after a partial capture' do
    write('app/services/pay.rb')
    partial = snapshot.merge('files' => {}, 'scope_paths' => {}, 'complete' => false,
                             'errors' => [{ 'reason' => 'scan_time_budget' }])

    manifest = finish(session(capture: partial))

    expect(manifest.data.fetch('errors')).to include('reason' => 'scan_time_budget')
    expect(manifest.data.fetch('errors')).not_to include(include('reason' => 'source_changed_during_extraction'))
    expect(verify(manifest)['state']).to eq('unknown')
  end

  it 'still reports a changed identity observed by both partial scans' do
    path = write('app/services/pay.rb', 'before')
    partial = snapshot.merge('complete' => false, 'errors' => [{ 'reason' => 'scan_time_budget' }])
    run = session(capture: partial)
    File.write(path, 'after')
    allow(run).to receive(:scan).and_return(snapshot.merge('complete' => false))

    expect(finish(run).data.fetch('errors')).to include('reason' => 'source_changed_during_extraction',
                                                        'path' => 'app/services/pay.rb')
  end

  it 'continues to later accessible files after a directory traversal error' do
    denied = File.join(@root, 'a_unreadable')
    FileUtils.mkdir_p(denied)
    write('config/locales/en.yml', 'en: {}')
    allow(Dir).to receive(:children).and_call_original
    allow(Dir).to receive(:children).with(denied, any_args).and_raise(Errno::EACCES)

    result = snapshot

    expect(result['complete']).to be(false)
    expect(result.fetch('errors')).to include('reason' => 'source_tree_unavailable', 'path' => 'a_unreadable')
    expect(result.fetch('files').keys).to include('config/locales/en.yml')
  end

  it 'caps diagnostics from uncaptured unit paths as well as loaded features' do
    run = session
    80.times do |index|
      path = "custom_loader/unit_#{index}.rb"
      write(path)
      run.consume_unit(:custom, path)
    end

    errors = finish(run).data.fetch('errors')

    expect(errors.size).to be <= 30
    expect(errors).to include(include('reason' => 'uncaptured_source_path'))
  end
end
