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

  def declared_session(operation)
    scopes = Woods::SourceInputs::Scopes.new(extra_roots: ['domain'])
    capture = Woods::SourceInputs::Scanner.new(root: @root, output_dir: @output, key: @key, scopes: scopes).call
    allow(Woods::SourceInputs::Handoff).to receive_messages(read: capture, extra_roots: ['domain'])
    described_class.new(root: @root, output_dir: @output, baseline_path: @baseline, operation: operation)
  end

  # A declared root's capture scope is rebuilt wholesale by a full run; an
  # incremental run carried the baseline's identity even after a consumer
  # proved the new bytes, so the index moved while freshness stayed drifted (F15).
  it 'refreshes the declared scope for a consumed declared-root path during an incremental run' do
    path = 'domain/billing/ledger.rb'
    write(path, 'before')
    baseline = declared_session('full')
    baseline.consume_unit(:models, path)
    persist(finish(baseline))

    write(path, 'after')
    run = declared_session('incremental')
    run.consume_unit(:models, path)
    manifest = finish(run, 2)

    expect(manifest.expanded.fetch('declared').fetch(path)).to eq(manifest.expanded.fetch('unit:models').fetch(path))
    expect(verify(manifest)['state']).to eq('current')
  end

  def persist(manifest)
    File.write(@baseline, JSON.generate(manifest.data))
  end

  def verify(manifest)
    Woods::SourceInputs::Verifier.new(manifest: manifest, output_dir: @output).call
  end

  describe 'the publication recheck under machine load' do
    # Every visited file costs this much wall clock on the recheck, as if the
    # machine were heavily loaded. The capture itself runs unstubbed.
    def slow_recheck(seconds_per_file)
      allow_any_instance_of(Woods::SourceInputs::Scanner).to receive(:monotonic) do |scanner|
        1_000.0 + (scanner.instance_variable_get(:@visited).to_i * seconds_per_file)
      end
    end

    it 'allows an unchanged tree the time its captured work needs instead of refusing' do
      1_000.times { |i| write("app/services/svc_#{i}.rb", "class Svc#{i}; end") }
      run = session
      slow_recheck(0.02)
      manifest = finish(run)
      expect(manifest.data.fetch('errors')).not_to include(include('reason' => 'scan_time_budget'))
      expect(manifest.data.fetch('errors')).to be_empty
    end

    it 'still refuses a recheck that outruns the work-scaled budget' do
      3.times { |i| write("app/services/svc_#{i}.rb", "class Svc#{i}; end") }
      run = session
      slow_recheck(5.0)
      expect(finish(run).data.fetch('errors')).to include('reason' => 'scan_time_budget')
    end

    def recheck_seconds(visited_files:, bytes:)
      capture = Woods::SourceInputs::Scanner.new(root: @root, output_dir: @output, key: @key).call
      capture['metrics'] = capture.fetch('metrics').merge('visited_files' => visited_files, 'bytes' => bytes)
      allow(Woods::SourceInputs::Handoff).to receive(:read).and_return(capture)
      described_class.new(root: @root, output_dir: @output, baseline_path: @baseline, operation: 'full')
                     .send(:recheck_seconds)
    end

    it 'scales the recheck budget between a ten-second floor and a two-minute ceiling' do
      write('app/services/svc.rb', 'class Svc; end')
      expect(recheck_seconds(visited_files: 1, bytes: 14)).to eq(10.0)
      expect(recheck_seconds(visited_files: 1_000, bytes: 4 * 1024 * 1024)).to eq(51.0)
      expect(recheck_seconds(visited_files: 11_192, bytes: 20_500_000)).to eq(120.0)
      expect(recheck_seconds(visited_files: 50_000, bytes: 128 * 1024 * 1024)).to eq(120.0)
    end

    it 'keeps the reader budget wall-clock' do
      1_000.times { |i| write("app/services/svc_#{i}.rb", "class Svc#{i}; end") }
      manifest = finish(session)
      slow_recheck(0.02)
      expect(verify(manifest)['state']).to eq('unknown')
      expect(verify(manifest)['reasons']).to include('scan_time_budget')
    end
  end

  describe 'the initial capture under machine load' do
    # The walk hashes app/ before lib/, so a capture cut short by its clock
    # loses the lib/ file a reference contributor reads last.
    def slow_capture_clock(seconds_per_file)
      allow_any_instance_of(Woods::SourceInputs::Scanner).to receive(:monotonic) do |scanner|
        1_000.0 + (scanner.instance_variable_get(:@visited).to_i * seconds_per_file)
      end
    end

    def slow_capture(seconds_per_file)
      40.times { |i| write("app/models/model_#{i}.rb", "class Model#{i}; end") }
      write('lib/ledger_client.rb', 'module LedgerClient; end')
      slow_capture_clock(seconds_per_file)
      session(verified: false)
    end

    def reference_pass(run)
      units = [{ 'type' => 'lib', 'identifier' => 'LedgerClient', 'file_path' => 'lib/ledger_client.rb',
                 'dependencies' => [] }]
      Woods::SourceReferences::Pass.new(root: @root, session: run, units: units,
                                        extractor_keys: { lib: :libs }, full: true).call
    end

    it 'captures every input of an unchanged tree that load slows past the quick-reader budget' do
      run = slow_capture(0.5)
      expect { reference_pass(run) }.not_to raise_error
      snapshot = run.instance_variable_get(:@snapshot)
      expect(snapshot).to include('complete' => true, 'errors' => [])
      expect(snapshot.fetch('files')).to have_key('lib/ledger_client.rb')
    end

    it 'still refuses source references when the capture stalls past its ceiling, naming the cap that fired' do
      run = slow_capture(5.0)
      expect(run.instance_variable_get(:@snapshot).fetch('errors')).to include('reason' => 'scan_time_budget')
      message = 'Source-reference input was not captured: lib/ledger_client.rb. ' \
                'The source capture was incomplete: scan_time_budget (120.0-second cap)'
      expect { reference_pass(run) }.to raise_error(Woods::ExtractionError, /\A#{Regexp.escape(message)}/)
    end

    {
      'scan_file_budget' => [{ max_files: 5 }, /scan_file_budget \(5-file cap\)/],
      'scan_byte_budget' => [{ max_bytes: 100 }, /scan_byte_budget \(100-byte cap\)/]
    }.each do |reason, (limits, message)|
      it "names #{reason} and its cap when the capture stops on it" do
        stub_const('Woods::SourceInputs::Scanner::DEFAULT_LIMITS',
                   Woods::SourceInputs::Scanner::DEFAULT_LIMITS.merge(limits))
        run = slow_capture(0.0)
        expect(run.instance_variable_get(:@snapshot).fetch('errors')).to include('reason' => reason)
        expect { reference_pass(run) }.to raise_error(Woods::ExtractionError, message)
      end
    end

    it 'names the capture error recorded for an uncaptured path when no cap fired' do
      write('lib/ledger_client.rb', 'module LedgerClient; end')
      capture = Woods::SourceInputs::Scanner.new(root: @root, output_dir: @output, key: @key).call
      capture['files'].delete('lib/ledger_client.rb')
      capture['scope_paths'].each_value { |paths| paths.delete('lib/ledger_client.rb') }
      capture.merge!('complete' => false,
                     'errors' => [{ 'reason' => 'source_changed_during_read', 'path' => 'lib/ledger_client.rb' }])
      allow(Woods::SourceInputs::Handoff).to receive(:read).and_return(capture)
      run = described_class.new(root: @root, output_dir: @output, baseline_path: @baseline, operation: 'full')
      message = 'The source capture was incomplete: source_changed_during_read (lib/ledger_client.rb)'
      expect { reference_pass(run) }.to raise_error(Woods::ExtractionError, /#{Regexp.escape(message)}/)
    end
  end

  describe 'source read capability' do
    it 'keeps an undecodable consumer path unverified with JSON-safe diagnostics' do
      path = 'app/services/bad_'.b + "\xFF.rb".b
      run = session
      expect { run.read_source(path) }
        .to raise_error(Woods::SourceInputs::StableReader::Error, 'uncaptured_source_path')
      run.consume_unit(:services, path)
      manifest = finish(run)
      expect(JSON.parse(JSON.generate(manifest.data))['errors'])
        .to include(include('reason' => 'undecodable_source_path', 'path' => include('\\xFF')))
      expect(verify(manifest)['state']).to eq('unknown')
    end

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
