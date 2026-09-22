# frozen_string_literal: true

# Standalone development regressions; run against a selected Woods checkout:
# bundle exec rspec -Ilib /absolute/path/to/this/file.rb
# These expectations intentionally fail on beta3 until the bugs are fixed.
require 'rspec'
require 'tmpdir'
require 'fileutils'
require 'json'
require 'woods/temporal/json_snapshot_store'
require 'woods/session_tracer/file_store'

RSpec.describe 'Release review follow-up regressions' do # rubocop:disable Metrics/BlockLength
  around do |example|
    Dir.mktmpdir('woods_release_review') do |dir|
      @directory = dir
      example.run
    end
  end

  it 'clears a supported non-legacy session ID without raising' do
    store = Woods::SessionTracer::FileStore.new(base_dir: @directory)
    store.record('user:é', { event: 'recorded' })
    expect { store.clear('user:é') }.not_to raise_error
    expect(store.read('user:é')).to eq([])
  end

  it 'starts a fresh history when an expired session receives another record' do
    store = Woods::SessionTracer::FileStore.new(base_dir: @directory, ttl: 60)
    store.record('session', { event: 'expired' })
    path = Dir.glob(File.join(@directory, '*.jsonl')).fetch(0)
    old = Time.now - 120
    File.utime(old, old, path)
    store.record('session', { event: 'new' })
    expect(store.read('session')).to eq([{ 'event' => 'new' }])
  end

  it 'skips a malformed retained unit entry when capturing a fresh snapshot' do
    store = Woods::Temporal::JsonSnapshotStore.new(dir: @directory)
    store.capture({ 'git_sha' => 'aaa111', 'extracted_at' => '2026-01-01T00:00:00Z' }, [])
    invalid = { 'git_sha' => 'bbb222', 'extracted_at' => '2026-01-02T00:00:00Z', 'units' => { 'User' => nil } }
    File.write(File.join(@directory, 'snapshots', 'bbb222.json'), JSON.generate(invalid))
    expect do
      store.capture({ 'git_sha' => 'ccc333', 'extracted_at' => '2026-01-03T00:00:00Z' }, [])
    end.not_to raise_error
    expect(store.find('ccc333')).not_to be_nil
  end

  it 'preserves unexpired history and clears an ordinary session ID' do
    store = Woods::SessionTracer::FileStore.new(base_dir: @directory, ttl: 60)
    store.record('session', { event: 'first' })
    store.record('session', { event: 'second' })
    expect(store.read('session').map { |row| row.fetch('event') }).to eq(%w[first second])
    expect { store.clear('session') }.not_to raise_error
    expect(store.read('session')).to eq([])
  end

  it 'expires an idle session on read' do
    store = Woods::SessionTracer::FileStore.new(base_dir: @directory, ttl: 60)
    store.record('session', { event: 'expired' })
    path = Dir.glob(File.join(@directory, '*.jsonl')).fetch(0)
    old = Time.now - 120
    File.utime(old, old, path)
    expect(store.read('session')).to eq([])
  end

  it 'captures a fresh snapshot when retained unit entries are valid' do
    store = Woods::Temporal::JsonSnapshotStore.new(dir: @directory)
    store.capture({ 'git_sha' => 'aaa111', 'extracted_at' => '2026-01-01T00:00:00Z' }, [])
    expect do
      store.capture({ 'git_sha' => 'ccc333', 'extracted_at' => '2026-01-03T00:00:00Z' }, [])
    end.not_to raise_error
    expect(store.find('ccc333')).not_to be_nil
  end
end
