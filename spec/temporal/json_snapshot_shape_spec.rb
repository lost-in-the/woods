# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'json'
require 'woods/temporal/json_snapshot_store'

RSpec.describe 'Persisted JSON snapshot shapes' do
  let(:directory) { Dir.mktmpdir('woods-snapshot-shape') }
  let(:store) { Woods::Temporal::JsonSnapshotStore.new(dir: directory, retention: 10) }
  let(:valid_unit) { { identifier: 'User', type: 'model', source_hash: 'original' } }
  let(:bad_path) { File.join(directory, 'snapshots', 'bbb222.json') }
  let(:bad_snapshot) do
    { 'git_sha' => 'bbb222', 'extracted_at' => '2026-02-01',
      'units' => { 'OnlyInDamagedSnapshot' => { 'unit_type' => 'model', 'source_hash' => 'keep-no-partial' } } }
  end

  before { store.capture({ git_sha: 'aaa111', extracted_at: '2026-01-01' }, [valid_unit]) }
  after { FileUtils.remove_entry(directory) }

  def write_bad(changes)
    File.write(bad_path, JSON.generate(bad_snapshot.merge(changes)))
  end

  shared_examples 'an unusable retained snapshot' do
    it 'warns and skips the entire file across find, list, diff, history and a later valid capture' do
      expect { expect(store.find('bbb222')).to be_nil }
        .to output(/Skipping corrupt snapshot bbb222\.json/).to_stderr
      expect { expect(store.list.map { |item| item[:git_sha] }).to eq(['aaa111']) }
        .to output(/Skipping corrupt snapshot bbb222\.json/).to_stderr
      expect { expect(store.diff('aaa111', 'bbb222')).to eq(added: [], modified: [], deleted: []) }
        .to output(/Skipping corrupt snapshot bbb222\.json/).to_stderr
      expect { expect(store.unit_history('User').map { |item| item[:git_sha] }).to eq(['aaa111']) }
        .to output(/Skipping corrupt snapshot bbb222\.json/).to_stderr
      expect { expect(store.unit_history('OnlyInDamagedSnapshot')).to be_empty }
        .to output(/Skipping corrupt snapshot bbb222\.json/).to_stderr

      expect do
        result = store.capture({ git_sha: 'ccc333', extracted_at: '2026-03-01' },
                               [valid_unit.merge(source_hash: 'changed'), { identifier: 'Added', type: 'model' }])
        expect(result).to include(git_sha: 'ccc333', units_added: 1, units_modified: 1, units_deleted: 0)
      end.to output(/Skipping corrupt snapshot bbb222\.json/).to_stderr
      expect(store.find('ccc333')).to include(git_sha: 'ccc333')
      expect(File).to exist(bad_path) # Reads do not delete a file below the retention limit.
    end
  end

  [nil, false, true, 42, 'text', [], [{}]].each do |record|
    context "with a unit record of #{record.inspect}" do
      before { write_bad('units' => bad_snapshot['units'].merge('User' => record)) }

      include_examples 'an unusable retained snapshot'
    end
  end

  [false, true, 42, 'text', [], [['User', {}]]].each do |units|
    context "with a units collection of #{units.inspect}" do
      before { write_bad('units' => units) }

      include_examples 'an unusable retained snapshot'
    end
  end

  [nil, 42, [], {}, false, '../outside', 'unknown'].each do |sha|
    context "with a persisted SHA of #{sha.inspect}" do
      before { write_bad('git_sha' => sha) }

      include_examples 'an unusable retained snapshot'
    end
  end

  [42, [], {}, false].each do |timestamp|
    context "with a timestamp of #{timestamp.inspect}" do
      before { write_bad('extracted_at' => timestamp) }

      include_examples 'an unusable retained snapshot'
    end
  end

  it 'preserves legacy bare keys, optional hashes and metadata, and typed identity comparison' do
    write_bad('units' => { 'User' => { 'unit_type' => 'model', 'source_hash' => 'original' } },
              'unit_counts' => nil, 'rails_version' => nil, 'future_metadata' => { 'anything' => [] })
    expect(store.list.map { |item| item[:git_sha] }).to eq(%w[bbb222 aaa111])
    expect(store.find('bbb222')).to include(git_sha: 'bbb222', unit_counts: {})
    expect(store.diff('aaa111', 'bbb222')).to eq(added: [], modified: [], deleted: [])
    expect(store.unit_history('User').map { |item| item[:changed] }).to eq([false, true])
    result = store.capture({ git_sha: 'ccc333', extracted_at: '2026-03-01' }, [valid_unit])
    expect(result).to include(units_added: 0, units_modified: 0, units_deleted: 0)
  end

  it 'accepts omitted or null units and timestamps without requiring optional record fields' do
    [{}, { 'units' => nil, 'extracted_at' => nil }, { 'units' => {}, 'extracted_at' => '' }].each do |fields|
      File.write(bad_path, JSON.generate({ 'git_sha' => 'bbb222' }.merge(fields)))
      expect(store.find('bbb222')).to include(git_sha: 'bbb222')
      expect(store.list.size).to eq(2)
      expect(store.unit_history('User').size).to eq(1)
      expect(store.diff('bbb222', 'aaa111')[:added]).to eq([{ identifier: 'User', unit_type: 'model' }])
    end
    write_bad('units' => { 'LegacyEmpty' => {} }, 'extracted_at' => 'not-an-ISO-timestamp')
    expect(store.unit_history('LegacyEmpty').first).to include(unit_type: nil, source_hash: nil)
    expect(store.list.first[:git_sha]).to eq('bbb222')
  end

  it 'counts invalid nested data toward retention and prunes it before a valid older snapshot' do
    write_bad('units' => { 'User' => nil })
    bounded = Woods::Temporal::JsonSnapshotStore.new(dir: directory, retention: 2)
    expect { bounded.capture({ git_sha: 'ccc333', extracted_at: '2025-01-01' }, [valid_unit]) }
      .to output(/Skipping corrupt snapshot bbb222\.json/).to_stderr
    expect(Dir.children(File.join(directory, 'snapshots')).sort).to eq(%w[aaa111.json ccc333.json])
    expect(bounded.find('ccc333')).to include(git_sha: 'ccc333')
  end

  it 'continues to reject invalid caller SHAs rather than treating them as missing persisted files' do
    expect { store.find('../outside') }.to raise_error(ArgumentError, /Invalid git SHA/)
    expect { store.diff('aaa111', 'not-a-sha') }.to raise_error(ArgumentError, /Invalid git SHA/)
    expect(store.capture({ git_sha: 'unknown' }, [])).to be_nil
  end

  it 'does not conceal unrelated programming errors raised while reading' do
    allow(Woods::AtomicFile).to receive(:read).and_raise(NoMethodError, 'programming defect')
    expect { store.find('aaa111') }.to raise_error(NoMethodError, 'programming defect')
  end
end
