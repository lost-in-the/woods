# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'woods/source_inputs/session'
require 'woods/source_inputs/verifier'
require 'woods/source_references/pass'

RSpec.describe Woods::SourceInputs::Session do
  around do |example|
    Dir.mktmpdir('woods-source-session') do |root|
      @root = root
      @output = File.join(root, 'index')
      @baseline = File.join(@output, 'source_inputs.json')
      @key = Woods::SourceInputs::PrivateKey.new(output_dir: @output, create: true)
      old = ENV.delete(Woods::SourceInputs::Handoff::ENV_KEY)
      example.run
    ensure
      ENV[Woods::SourceInputs::Handoff::ENV_KEY] = old
    end
  end

  def write(path, bytes)
    target = File.join(@root, path)
    FileUtils.mkdir_p(File.dirname(target))
    File.binwrite(target, bytes)
  end

  def session(operation = 'full', verified: true)
    if verified
      capture = Woods::SourceInputs::Scanner.new(root: @root, output_dir: @output, key: @key).call
      allow(Woods::SourceInputs::Handoff).to receive(:read).and_return(capture)
    else
      allow(Woods::SourceInputs::Handoff).to receive(:read).and_return(nil)
    end
    described_class.new(root: @root, output_dir: @output, baseline_path: @baseline, operation: operation)
  end

  def finish(run, generation = 1)
    run.finish(generation: generation, eager_load_complete: true)
  end

  def persist(manifest)
    File.write(@baseline, JSON.generate(manifest.data))
  end

  def verify(manifest)
    Woods::SourceInputs::Verifier.new(manifest: manifest, output_dir: @output).call
  end

  describe 'source read capability' do
    it 'reads captured bytes without claiming the unit consumed them' do
      path = 'app/services/pay.rb'
      write(path, 'class Pay; end')
      run = session
      expect(run.source_identity(path)).to eq(OpenSSL::HMAC.hexdigest('SHA256', @key.bytes, 'class Pay; end'))
      expect(run.consumed_source?(:services, path)).to be(false)
      result = run.read_source(path)
      expect(result).to include('path' => path, 'source' => 'class Pay; end', 'identity' => run.source_identity(path))
      expect(run.consumed_source?(:services, path)).to be(false)
      run.consume_unit(:services, path)
      expect(run.consumed_source?(:services, path)).to be(true)
    end

    it 'distinguishes retained consumption from changed current snapshot bytes' do
      path = 'app/services/pay.rb'
      write(path, 'before')
      baseline_run = session
      baseline_run.consume_unit(:services, path)
      persist(finish(baseline_run))
      expect(session('incremental').consumed_source?(:services, path)).to be(true)
      write(path, 'after')
      run = session('incremental')
      expect(run.consumed_source?(:services, path)).to be(false)
      expect(run.read_source(path)['source']).to eq('after')
      expect(run.consumed_source?(:services, path)).to be(false)
      run.consume_unit(:services, path)
      expect(run.consumed_source?(:services, path)).to be(true)
    end

    it 'keeps missing or legacy unit ledgers unproven despite matching file scopes' do
      path = 'app/services/pay.rb'
      write(path, 'before')
      expect(session('incremental').consumed_source?(:services, path)).to be(false)
      persist(finish(session))
      run = session('incremental')
      expect(run.read_source(path)['source']).to eq('before')
      expect(run.consumed_source?(:services, path)).to be(false)
      expect(run.consumed_source?(:poros, path)).to be(false)
    end

    it 'refuses uncaptured paths, unavailable identities and edits after session creation' do
      path = 'app/services/pay.rb'
      write(path, 'before')
      run = session
      write('app/services/new.rb', 'new')
      expect(run.source_identity('../foreign.rb')).to be_nil
      expect(run.consumed_source?(:services, '../foreign.rb')).to be(false)
      expect { run.read_source('app/services/new.rb') }
        .to raise_error(Woods::SourceInputs::StableReader::Error, 'uncaptured_source_path')
      write(path, 'after')
      expect { run.read_source(path) }
        .to raise_error(Woods::SourceInputs::StableReader::Error, 'source_snapshot_mismatch')
      File.chmod(0o644, File.join(@output, Woods::SourceInputs::PrivateKey::FILE_NAME))
      expect { session.read_source(path) }
        .to raise_error(Woods::SourceInputs::StableReader::Error, 'source_identity_unavailable')
    end
  end

  it 'retains pre-consumption bytes when a source changes while extraction runs' do
    write('app/services/pay.rb', 'before')
    run = session
    write('app/services/pay.rb', 'after')
    manifest = finish(run)
    expect(verify(manifest)).to include('state' => 'drifted')
    expect(manifest.data['errors']).to include('reason' => 'source_changed_during_extraction',
                                               'path' => 'app/services/pay.rb')
    expected = OpenSSL::HMAC.hexdigest('SHA256', @key.bytes, 'before')
    expect(manifest.expanded['file:services']['app/services/pay.rb']).to eq(expected)
  end

  it 'retains an omitted dirty consumer when a whole-app extractor consumes the same file' do
    path = 'app/services/pay.rb'
    write(path, 'before')
    baseline = finish(session)
    persist(baseline)
    write(path, 'after')
    run = session('incremental')
    run.consume_extractor(:events, [])
    manifest = finish(run, 2)
    expect(manifest.expanded['whole:events'][path]).not_to eq(baseline.expanded['whole:events'][path])
    expect(manifest.expanded['file:services'][path]).to eq(baseline.expanded['file:services'][path])
    expect(verify(manifest)['changes']['changed']).to include(path)
  end

  it 'records successful negative extraction and deletion without retaining phantom unit identities' do
    path = 'app/views/posts/show.html.erb'
    write(path, 'before')
    run = session
    run.consume_unit(:view_templates, path)
    persist(finish(run))
    write(path, 'after')
    run = session('incremental')
    run.consume_file(:view_templates, path)
    manifest = finish(run, 2)
    expect(manifest.expanded['unit:view_templates'][path]).to eq(manifest.expanded['file:view_templates'][path])
    persist(manifest)
    FileUtils.rm(File.join(@root, path))
    run = session('incremental')
    run.consume_deleted(path)
    manifest = finish(run, 3)
    expect(manifest.expanded.values.flat_map(&:keys)).not_to include(path)
    expect(verify(manifest)['state']).to eq('current')
  end

  it 'does not advance boot inputs during a named refresh' do
    path = 'config/initializers/billing.rb'
    write(path, 'before')
    baseline = finish(session)
    persist(baseline)
    write(path, 'after')
    run = session('refresh')
    run.consume_extractor(:configuration, [])
    manifest = finish(run, 2)
    expect(manifest.expanded['boot'][path]).to eq(baseline.expanded['boot'][path])
    expect(verify(manifest)['state']).to eq('drifted')
  end

  it 'qualifies unproved runtime consumption and post-boot capture as unknown' do
    write('app/services/pay.rb', 'before')
    persist(finish(session))
    write('app/services/pay.rb', 'after')
    run = session('incremental')
    run.consume_file(:services, 'app/services/pay.rb')
    run.consume_file(:concerns, 'app/services/pay.rb')
    run.consume_extractor(:events, [])
    manifest = finish(run, 2)
    expect(manifest.data['unverified_scopes']).to include('runtime_consumption')
    expect(verify(manifest)['state']).to eq('unknown')
    expect(verify(finish(session(verified: false)))['reasons']).to include('unverified_boot_boundary')
  end

  it 'does not mistake built-in relative feature names for application files' do
    run = session
    $LOADED_FEATURES << 'woods_builtin_fixture.so'
    expect(verify(finish(run))['state']).to eq('current')
  ensure
    $LOADED_FEATURES.delete('woods_builtin_fixture.so')
  end

  it 'keeps custom loaded Ruby outside captured roots unknown without adopting its final bytes' do
    path = 'custom_runtime/loader.rb'
    write(path, 'custom loader')
    run = session
    $LOADED_FEATURES << File.join(@root, path)
    manifest = finish(run)
    expect(manifest.data['errors']).to include('reason' => 'loaded_source_outside_coverage', 'path' => path)
    expect(verify(manifest)['state']).to eq('unknown')
  ensure
    $LOADED_FEATURES.delete(File.join(@root, path))
  end

  it 'marks a failed full consumer unknown while certifying an unaffected consumer' do
    write('app/services/pay.rb', 'before')
    failed = Object.new
    Woods::SourceInputs::ConsumerErrors.record(failed)
    run = session
    run.full_units({ services: [], events: [] }, consumers: { services: failed, events: Object.new })
    manifest = finish(run)
    expect(manifest.data['unverified_scopes']).to eq(['extractor:services'])
    expect(manifest.expanded['whole:events']).to include('app/services/pay.rb')
    expect(verify(manifest)['state']).to eq('unknown')
  end

  it 'keeps incomplete prior coverage until a complete full extraction replaces it' do
    write('app/services/pay.rb', 'before')
    run = session
    run.unverified('custom_loader')
    persist(finish(run))
    expect(finish(session('refresh'), 2).data['unverified_scopes']).to include('custom_loader')
    expect(verify(finish(session, 3))['state']).to eq('current')
  end

  it 'retains successful model consumption while a sibling model fails' do
    good = 'app/models/credential.rb'
    failed_path = 'app/models/unavailable.rb'
    write(good, 'class Credential; end')
    write(failed_path, 'class Unavailable; end')
    consumer = Object.new
    Woods::SourceInputs::ConsumerErrors.record(consumer)
    run = session
    run.full_units({ models: [double(file_path: good)] }, consumers: { models: consumer })
    manifest = finish(run)

    expect(manifest.data['unverified_scopes']).to include('extractor:models')
    expect(verify(manifest)['state']).to eq('unknown')
    expect(run.consumed_source?(:models, good)).to be(true)
    expect(run.consumed_source?(:models, failed_path)).to be(false)
    units = [{ 'type' => 'model', 'identifier' => 'Credential', 'file_path' => good, 'dependencies' => [] }]
    args = { root: @root, units: units, extractor_keys: { model: :models } }
    cache = Woods::SourceReferences::Pass.new(**args, session: run, full: true).call.cache
    persist(manifest)
    retained = session('incremental')
    expect(retained.consumed_source?(:models, good)).to be(true)
    expect(retained.consumed_source?(:models, failed_path)).to be(false)
    expect { Woods::SourceReferences::Pass.new(**args, session: retained, baseline: cache).call }.not_to raise_error

    write(good, 'class Credential; def changed; end; end')
    changed = session('incremental')
    expect(changed.consumed_source?(:models, good)).to be(false)
    expect { Woods::SourceReferences::Pass.new(**args, session: changed, baseline: cache).call }
      .to raise_error(Woods::SourceReferences::RebuildRequired, /unverified source/)
  end

  it 'does not certify partial output from other failed extractor families' do
    path = 'app/services/pay.rb'
    write(path, 'class Pay; end')
    consumer = Object.new
    Woods::SourceInputs::ConsumerErrors.record(consumer)
    run = session
    run.full_units({ events: [double(file_path: path)] }, consumers: { events: consumer })

    expect(run.consumed_source?(:events, path)).to be(false)
    expect(finish(run).data['unverified_scopes']).to include('extractor:events')
  end

  it 'keeps missing old provenance and insecure keys explicit without repairing the key' do
    errors = finish(session('incremental')).data['errors']
    expect(errors).to include('reason' => 'missing_or_incompatible_source_baseline')
    File.chmod(0o644, File.join(@output, Woods::SourceInputs::PrivateKey::FILE_NAME))
    manifest = finish(session)
    expect(manifest.data['complete']).to be(false)
    expect(verify(manifest)['reasons']).to include('insecure_identity_key')
  end
end
