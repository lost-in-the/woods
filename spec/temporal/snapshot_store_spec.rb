# frozen_string_literal: true

require 'spec_helper'
require 'sqlite3'
require 'woods/db/migrator'
require 'woods/temporal/snapshot_store'

RSpec.describe Woods::Temporal::SnapshotStore do
  let(:db) do
    d = SQLite3::Database.new(':memory:')
    d.results_as_hash = true
    Woods::Db::Migrator.new(connection: d).migrate!
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
      count = db.get_first_value('SELECT COUNT(*) FROM woods_snapshot_units')
      expect(count).to eq(3)
    end

    it 'is idempotent — same git SHA overwrites cleanly' do
      store.capture(manifest_v1, units_v1)
      store.capture(manifest_v1, units_v1)
      count = db.get_first_value('SELECT COUNT(*) FROM woods_snapshots')
      expect(count).to eq(1)
    end

    # #206 — INSERT OR REPLACE deleted the old snapshot row and minted a new
    # autoincrement id, so the per-unit DELETE keyed on the new id removed
    # nothing and every re-extraction at an unchanged HEAD leaked a full
    # unit-hash set (foreign keys are never enabled on this connection).
    it 'does not leak unit rows when the same SHA is captured twice (#206)' do
      store.capture(manifest_v1, units_v1)
      store.capture(manifest_v1, units_v1)

      count = db.get_first_value('SELECT COUNT(*) FROM woods_snapshot_units')
      expect(count).to eq(units_v1.size)
    end

    it 'keeps the snapshot row id stable across re-capture (#206)' do
      first_id = store.capture(manifest_v1, units_v1)[:id]
      second_id = store.capture(manifest_v1, units_v1)[:id]

      expect(second_id).to eq(first_id)
    end

    it 'sweeps unit rows orphaned by a pre-#206 leak' do
      db.execute(<<~SQL, [999, 'Ghost', 'model', 'h9', 'm9', 'd9'])
        INSERT INTO woods_snapshot_units
          (snapshot_id, identifier, unit_type, source_hash, metadata_hash, dependencies_hash)
        VALUES (?, ?, ?, ?, ?, ?)
      SQL

      store.capture(manifest_v1, units_v1)

      orphans = db.get_first_value('SELECT COUNT(*) FROM woods_snapshot_units WHERE snapshot_id = 999')
      expect(orphans).to eq(0)
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

    it 'uses one transaction for the complete capture' do
      allow(db).to receive(:transaction).and_call_original

      store.capture(manifest_v1, units_v1)

      expect(db).to have_received(:transaction).once
    end

    it 'rolls back the snapshot row, units, pruning, and diff state together' do
      original = store.capture(manifest_v1, units_v1)
      allow(db).to receive(:execute).and_call_original
      allow(db).to receive(:execute)
        .with(/UPDATE woods_snapshots SET units_added/, anything)
        .and_raise(SQLite3::SQLException, 'forced diff failure')

      expect { store.capture(manifest_v1, units_v2) }
        .to raise_error(SQLite3::SQLException, 'forced diff failure')

      snapshot = store.find(manifest_v1.fetch('git_sha'))
      rows = db.execute(
        'SELECT identifier, source_hash FROM woods_snapshot_units WHERE snapshot_id = ?',
        [original.fetch(:id)]
      )
      expect(snapshot[:total_units]).to eq(manifest_v1.fetch('total_units'))
      expect(rows.to_h { |row| [row['identifier'], row['source_hash']] }).to eq(
        'User' => 'h1',
        'Post' => 'h2',
        'AuthService' => 'h3'
      )
    end

    it 'keeps concurrent captures complete across separate SQLite connections' do
      Dir.mktmpdir('woods-temporal-concurrency') do |dir|
        database = File.join(dir, 'temporal.sqlite3')
        setup = SQLite3::Database.new(database)
        Woods::Db::Migrator.new(connection: setup).migrate!
        setup.close

        connections = 2.times.map do
          SQLite3::Database.new(database).tap { |connection| connection.results_as_hash = true }
        end
        stores = connections.map { |connection| described_class.new(connection: connection) }
        ready = Queue.new
        start = Queue.new
        errors = Queue.new
        captures = [[stores[0], manifest_v1, units_v1], [stores[1], manifest_v2, units_v2]]
        threads = captures.map do |capture_store, manifest, units|
          Thread.new do
            ready << true
            start.pop
            capture_store.capture(manifest, units)
          rescue StandardError => e
            errors << e
          end
        end
        2.times { ready.pop }
        2.times { start << true }
        threads.each(&:join)

        expect(errors.size).to eq(0), errors.size.times.map { errors.pop.full_message }.join("\n")
        verifier = connections.first
        expect(verifier.get_first_value('SELECT COUNT(*) FROM woods_snapshots')).to eq(2)
        expect(verifier.get_first_value('SELECT COUNT(*) FROM woods_snapshot_units')).to eq(6)
      ensure
        connections&.each(&:close)
      end
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
      db.execute('DELETE FROM woods_snapshot_units')
      db.execute('DELETE FROM woods_snapshots')
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

  # ── diff / history across a re-captured SHA (#206) ─────────────────

  describe 'diff and history across a re-captured SHA' do
    before do
      store.capture(manifest_v1, units_v1)
      store.capture(manifest_v1, units_v1) # re-extraction at an unchanged HEAD
      store.capture(manifest_v2, units_v2)
    end

    it 'diffs the two SHAs exactly as if each had been captured once' do
      result = store.diff('aaa1111', 'bbb2222')

      expect(result[:added].map { |u| u[:identifier] }).to contain_exactly('Comment')
      expect(result[:modified].map { |u| u[:identifier] }).to contain_exactly('User')
      expect(result[:deleted].map { |u| u[:identifier] }).to contain_exactly('Post')
    end

    it 'keeps unit history at one entry per SHA' do
      expect(store.unit_history('User').map { |e| e[:git_sha] }).to eq(%w[bbb2222 aaa1111])
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
