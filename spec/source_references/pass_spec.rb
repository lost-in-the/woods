# frozen_string_literal: true

require 'spec_helper'
require 'woods/source_references/pass'
require 'woods/source_inputs/stable_reader'

RSpec.describe Woods::SourceReferences::Pass do
  let(:root) { '/reference-app' }
  let(:sources) do
    {
      'app/models/ref_caller.rb' => 'class RefCaller; def call; RefTarget.new; end; end',
      'app/models/ref_target.rb' => 'class RefTarget; end'
    }
  end
  let(:session) { double('Source session') }
  let(:collector) { Woods::SourceReferences::Collector.new }
  let(:units) { sources.keys.zip(%w[RefCaller RefTarget]).map { |path, id| unit(id, path) } }

  before do
    stub_const('RefCaller', Class.new)
    stub_const('RefTarget', Class.new)
    allow(session).to receive(:source_identity) { |path| sources.key?(path) ? Digest::SHA256.hexdigest(sources[path]) : nil }
    allow(session).to receive(:read_source) do |path|
      { 'path' => path, 'source' => sources.fetch(path), 'identity' => Digest::SHA256.hexdigest(sources.fetch(path)) }
    end
    allow(session).to receive(:consumed_source?).and_return(true)
  end

  def unit(id, path, type = 'poro')
    { 'identifier' => id, 'type' => type, 'file_path' => path, 'dependencies' => [],
      'metadata' => { 'git' => { 'commit_count' => 7 } }, 'extracted_at' => 'preserved' }
  end

  def run_pass(baseline: nil, refreshed: [], full: true)
    described_class.new(root: root, session: session, units: units, baseline: baseline,
                        refreshed: refreshed, full: full, collector: collector,
                        extractor_keys: { poro: :poros, lib: :lib, model: :models }).call
  end

  def edge(target = 'RefTarget')
    { 'type' => 'poro', 'target' => target, 'via' => 'code_reference' }
  end

  it 'adds a resolved edge using captured source while retaining other unit data' do
    result = run_pass
    expect(result.dependencies.fetch(%w[poro RefCaller])).to eq([edge])
    expect(units.first['dependencies']).to eq([])
    expect(result.cache['owners']).to include(hash_including('identifier' => 'RefCaller', 'added' => [edge]))
    expect(result.cache['files'].keys).to match_array(sources.keys)
  end

  it 'caches unresolved candidates so a new target updates an unchanged caller without parsing it again' do
    units.pop
    initial = run_pass
    expect(initial.dependencies.fetch(%w[poro RefCaller])).to be_empty
    units << unit('RefTarget', 'app/models/ref_target.rb')
    expect(collector).to receive(:call).with(sources.fetch('app/models/ref_target.rb')).once.and_call_original
    expect(collector).not_to receive(:call).with(sources.fetch('app/models/ref_caller.rb'))
    result = run_pass(baseline: initial.cache, refreshed: [%w[poro RefTarget]], full: false)
    expect(result.dependencies.fetch(%w[poro RefCaller])).to eq([edge])
  end

  it 'withdraws only its own additions when a target disappears' do
    initial = run_pass
    units.first['dependencies'] = [edge, { 'type' => 'model', 'target' => 'Account', 'via' => 'belongs_to' }]
    units.pop
    result = run_pass(baseline: initial.cache, full: false)
    expect(result.dependencies.fetch(%w[poro RefCaller])).to eq([
                                                                  { 'type' => 'model', 'target' => 'Account',
                                                                    'via' => 'belongs_to' }
                                                                ])
  end

  it 'keeps an identical legacy scanner edge independent of this pass' do
    units.first['dependencies'] = [edge]
    initial = run_pass
    expect(initial.cache['owners'].find { |entry| entry['identifier'] == 'RefCaller' }['added']).to eq([])
    units.pop
    expect(run_pass(baseline: initial.cache, full: false).dependencies.fetch(%w[poro RefCaller])).to eq([edge])
  end

  it 'does not subtract previous additions from freshly re-extracted scanner results' do
    initial = run_pass
    units.first['dependencies'] = [edge]
    units.pop
    expect(run_pass(baseline: initial.cache, refreshed: [%w[poro RefCaller]], full: false)
      .dependencies.fetch(%w[poro RefCaller])).to eq([edge])
  end

  it 'removes stale additions when a formerly unique target becomes type-ambiguous' do
    initial = run_pass
    units.first['dependencies'] = [edge]
    units << unit('RefTarget', 'app/models/ref_target.rb', 'model')
    result = run_pass(baseline: initial.cache, refreshed: [%w[model RefTarget]], full: false)
    expect(result.dependencies.fetch(%w[poro RefCaller])).to eq([])
  end

  it 'requires a rebuild rather than resolve current source against stale retained metadata' do
    initial = run_pass
    allow(session).to receive(:consumed_source?).with(:poros, 'app/models/ref_caller.rb').and_return(false)
    expect { run_pass(baseline: initial.cache, full: false) }.to raise_error(
      Woods::SourceReferences::RebuildRequired, /full extraction/i
    )
  end

  it 'does not let a refreshed sibling certify changed source for a retained typed caller' do
    initial = run_pass
    units.first['dependencies'] = [edge]
    sources['app/models/ref_caller.rb'] += "\n# changed since this unit was extracted\n"
    # A sibling unit can acknowledge the same path in the per-extractor ledger.
    allow(session).to receive(:consumed_source?).and_return(true)
    expect { run_pass(baseline: initial.cache, refreshed: [%w[poro RefTarget]], full: false) }
      .to raise_error(Woods::SourceReferences::RebuildRequired, /unverified source/)
  end

  it 'requires a rebuild when a retained caller loses its ownership record' do
    initial = run_pass
    units.first['dependencies'] = [edge]
    initial.cache['owners'].reject! { |owner| owner['identifier'] == 'RefCaller' }
    units.pop
    expect { run_pass(baseline: initial.cache, full: false) }
      .to raise_error(Woods::SourceReferences::RebuildRequired, /ownership/)
  end

  it 'requires matching ownership source paths before removing prior additions' do
    initial = run_pass
    units.first['dependencies'] = [edge]
    initial.cache['owners'].find { |owner| owner['identifier'] == 'RefCaller' }['file_path'] = 'app/models/other.rb'
    expect { run_pass(baseline: initial.cache, full: false) }
      .to raise_error(Woods::SourceReferences::RebuildRequired, /ownership/)
  end

  it 'rejects a lost cache on an incremental run' do
    expect { run_pass(full: false) }.to raise_error(Woods::SourceReferences::RebuildRequired)
  end

  it 'refuses an existing eligible source omitted from the capture' do
    path = 'app/models/ref_caller.rb'
    allow(session).to receive(:source_identity).with(path).and_return(nil)
    allow(File).to receive(:exist?).and_call_original
    allow(File).to receive(:exist?).with(File.join(root, path)).and_return(true)
    expect { run_pass }.to raise_error(Woods::ExtractionError, /capture/)
  end

  it 'fails a syntax error rather than publishing a falsely empty edge set' do
    sources['app/models/ref_caller.rb'] = 'class RefCaller; def'
    expect { run_pass }.to raise_error(Woods::ExtractionError, /parse/)
  end

  it 'reports a captured-source read failure with the path and retry guidance' do
    error = Woods::SourceInputs::StableReader::Error.new('source_snapshot_mismatch')
    allow(session).to receive(:read_source).with('app/models/ref_caller.rb').and_raise(error)
    expect { run_pass }.to raise_error(
      Woods::ExtractionError, %r{app/models/ref_caller.rb.*source_snapshot_mismatch.*fresh process}
    )
  end

  it 'excludes external, generated and vendored files from source analysis' do
    units << unit('Outside', '/gems/outside.rb')
    units << unit('Vendor', 'vendor/bundle/vendor.rb')
    units << unit('Asset', 'app/assets/example.rb')
    expect(session).not_to receive(:read_source).with('/gems/outside.rb')
    expect(session).not_to receive(:read_source).with('vendor/bundle/vendor.rb')
    expect(session).not_to receive(:read_source).with('app/assets/example.rb')
    expect(run_pass.cache['files'].keys).to match_array(sources.keys)
  end
end
