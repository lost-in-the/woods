# frozen_string_literal: true

require 'spec_helper'
require 'sqlite3'
require 'codebase_index/db/migrator'
require 'codebase_index/temporal/snapshot_store'

RSpec.describe CodebaseIndex::Temporal::SnapshotStore do
  let(:db) do
    d = SQLite3::Database.new(':memory:')
    d.results_as_hash = true
    CodebaseIndex::Db::Migrator.new(connection: d).migrate!
    d
  end

  subject(:store) { described_class.new(connection: db) }

  let(:manifest_v1) do
    {
      'git_sha' => 'aaa1111',
      'git_branch' => 'main',
      'extracted_at' => '2026-01-01T10:00:00Z',
      'rails_version' => '8.1.0',
      'ruby_version' => '3.3.0',
      'total_units' => 3,
      'counts' => { 'models' => 2, 'services' => 1 },
      'gemfile_lock_sha' => 'lock_hash_1',
      'schema_sha' => 'schema_hash_1'
    }
  end

  let(:units_v1) do
    [
      { identifier: 'User', type: 'model', source_hash: 'h1', metadata_hash: 'm1', dependencies_hash: 'd1' },
      { identifier: 'Post', type: 'model', source_hash: 'h2', metadata_hash: 'm2', dependencies_hash: 'd2' },
      { identifier: 'AuthService', type: 'service', source_hash: 'h3', metadata_hash: 'm3', dependencies_hash: 'd3' }
    ]
  end

  let(:manifest_v2) do
    {
      'git_sha' => 'bbb2222',
      'git_branch' => 'main',
      'extracted_at' => '2026-01-02T10:00:00Z',
      'rails_version' => '8.1.0',
      'ruby_version' => '3.3.0',
      'total_units' => 3,
      'counts' => { 'models' => 2, 'services' => 1 },
      'gemfile_lock_sha' => 'lock_hash_1',
      'schema_sha' => 'schema_hash_1'
    }
  end

  let(:units_v2) do
    [
      { identifier: 'User', type: 'model', source_hash: 'h1_changed', metadata_hash: 'm1', dependencies_hash: 'd1' },
      { identifier: 'Comment', type: 'model', source_hash: 'h4', metadata_hash: 'm4', dependencies_hash: 'd4' },
      { identifier: 'AuthService', type: 'service', source_hash: 'h3', metadata_hash: 'm3', dependencies_hash: 'd3' }
    ]
  end

  # ── capture ────────────────────────────────────────────────────────

  describe '#capture' do
    it 'stores a snapshot record keyed by git SHA' do
      result = store.capture(manifest_v1, units_v1)
      expect(result[:git_sha]).to eq('aaa1111')
      expect(result[:total_units]).to eq(3)
    end

    it 'stores per-unit records linked to snapshot' do
      store.capture(manifest_v1, units_v1)
      count = db.get_first_value('SELECT COUNT(*) FROM codebase_snapshot_units')
      expect(count).to eq(3)
    end

    it 'is idempotent — same git SHA overwrites cleanly' do
      store.capture(manifest_v1, units_v1)
      store.capture(manifest_v1, units_v1)
      count = db.get_first_value('SELECT COUNT(*) FROM codebase_snapshots')
      expect(count).to eq(1)
    end

    it 'computes diff stats vs previous snapshot' do
      store.capture(manifest_v1, units_v1)
      result = store.capture(manifest_v2, units_v2)

      # User modified (source_hash changed), Post deleted, Comment added
      expect(result[:units_added]).to eq(1)     # Comment
      expect(result[:units_modified]).to eq(1)  # User
      expect(result[:units_deleted]).to eq(1)   # Post
    end

    it 'handles first-ever snapshot gracefully (no previous)' do
      result = store.capture(manifest_v1, units_v1)
      expect(result[:units_added]).to eq(0)
      expect(result[:units_modified]).to eq(0)
      expect(result[:units_deleted]).to eq(0)
    end

    it 'returns nil when git_sha is nil' do
      result = store.capture({ 'git_sha' => nil }, units_v1)
      expect(result).to be_nil
    end

    it 'stores manifest metadata correctly' do
      store.capture(manifest_v1, units_v1)
      snapshot = store.find('aaa1111')

      expect(snapshot[:git_branch]).to eq('main')
      expect(snapshot[:rails_version]).to eq('8.1.0')
      expect(snapshot[:ruby_version]).to eq('3.3.0')
      expect(snapshot[:unit_counts]).to eq({ 'models' => 2, 'services' => 1 })
      expect(snapshot[:gemfile_lock_sha]).to eq('lock_hash_1')
      expect(snapshot[:schema_sha]).to eq('schema_hash_1')
    end
  end

  # ── list ───────────────────────────────────────────────────────────

  describe '#list' do
    before do
      store.capture(manifest_v1, units_v1)
      store.capture(manifest_v2, units_v2)
    end

    it 'returns snapshots sorted by extracted_at descending' do
      result = store.list
      expect(result.size).to eq(2)
      expect(result.first[:git_sha]).to eq('bbb2222')
      expect(result.last[:git_sha]).to eq('aaa1111')
    end

    it 'respects limit' do
      result = store.list(limit: 1)
      expect(result.size).to eq(1)
      expect(result.first[:git_sha]).to eq('bbb2222')
    end

    it 'filters by branch' do
      feature_manifest = manifest_v1.merge('git_sha' => 'ccc3333', 'git_branch' => 'feature',
                                           'extracted_at' => '2026-01-03T10:00:00Z')
      store.capture(feature_manifest, units_v1)

      result = store.list(branch: 'feature')
      expect(result.size).to eq(1)
      expect(result.first[:git_branch]).to eq('feature')
    end

    it 'returns empty array when no snapshots exist' do
      empty_store = described_class.new(connection: db)
      db.execute('DELETE FROM codebase_snapshot_units')
      db.execute('DELETE FROM codebase_snapshots')
      expect(empty_store.list).to eq([])
    end
  end

  # ── find ───────────────────────────────────────────────────────────

  describe '#find' do
    it 'returns snapshot metadata for valid git SHA' do
      store.capture(manifest_v1, units_v1)
      result = store.find('aaa1111')
      expect(result[:git_sha]).to eq('aaa1111')
      expect(result[:total_units]).to eq(3)
    end

    it 'returns nil for unknown git SHA' do
      expect(store.find('nonexistent')).to be_nil
    end
  end

  # ── diff ───────────────────────────────────────────────────────────

  describe '#diff' do
    before do
      store.capture(manifest_v1, units_v1)
      store.capture(manifest_v2, units_v2)
    end

    it 'returns added units' do
      result = store.diff('aaa1111', 'bbb2222')
      added = result[:added].map { |u| u[:identifier] }
      expect(added).to contain_exactly('Comment')
    end

    it 'returns modified units' do
      result = store.diff('aaa1111', 'bbb2222')
      modified = result[:modified].map { |u| u[:identifier] }
      expect(modified).to contain_exactly('User')
    end

    it 'returns deleted units' do
      result = store.diff('aaa1111', 'bbb2222')
      deleted = result[:deleted].map { |u| u[:identifier] }
      expect(deleted).to contain_exactly('Post')
    end

    it 'returns empty diff when comparing same snapshot' do
      result = store.diff('aaa1111', 'aaa1111')
      expect(result[:added]).to eq([])
      expect(result[:modified]).to eq([])
      expect(result[:deleted]).to eq([])
    end

    it 'returns empty diff for unknown SHAs' do
      result = store.diff('unknown1', 'unknown2')
      expect(result[:added]).to eq([])
      expect(result[:modified]).to eq([])
      expect(result[:deleted]).to eq([])
    end
  end

  # ── unit_history ───────────────────────────────────────────────────

  describe '#unit_history' do
    before do
      store.capture(manifest_v1, units_v1)
      store.capture(manifest_v2, units_v2)
    end

    it 'returns all versions of a unit across snapshots' do
      result = store.unit_history('User')
      expect(result.size).to eq(2)
    end

    it 'includes git_sha, extracted_at, and source_hash' do
      result = store.unit_history('User')
      entry = result.first
      expect(entry).to have_key(:git_sha)
      expect(entry).to have_key(:extracted_at)
      expect(entry).to have_key(:source_hash)
    end

    it 'marks changed entries where source_hash differs' do
      result = store.unit_history('User')
      # Most recent (bbb2222) has different source_hash from previous → changed: true
      expect(result.first[:changed]).to be true
      # Oldest entry is always changed (first appearance)
      expect(result.last[:changed]).to be true
    end

    it 'marks unchanged entries where source_hash is the same' do
      result = store.unit_history('AuthService')
      # Both snapshots have same source_hash → newest is changed: false
      expect(result.first[:changed]).to be false
      # Oldest is always changed
      expect(result.last[:changed]).to be true
    end

    it 'returns empty array for unknown identifier' do
      expect(store.unit_history('NonExistent')).to eq([])
    end

    it 'respects limit' do
      result = store.unit_history('User', limit: 1)
      expect(result.size).to eq(1)
    end

    it 'returns results sorted by extracted_at descending' do
      result = store.unit_history('User')
      expect(result.first[:git_sha]).to eq('bbb2222')
      expect(result.last[:git_sha]).to eq('aaa1111')
    end
  end
end
