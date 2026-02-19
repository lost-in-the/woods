# frozen_string_literal: true

require 'spec_helper'
require 'codebase_index/db/migrator'
require 'sqlite3'

RSpec.describe 'Snapshot migrations' do
  let(:db) { SQLite3::Database.new(':memory:') }

  before do
    db.results_as_hash = true
    CodebaseIndex::Db::Migrator.new(connection: db).migrate!
  end

  describe 'Migration 004: CreateSnapshots' do
    it 'creates codebase_snapshots table' do
      tables = db.execute("SELECT name FROM sqlite_master WHERE type='table'").map { |r| r['name'] }
      expect(tables).to include('codebase_snapshots')
    end

    it 'has expected columns' do
      columns = db.execute('PRAGMA table_info(codebase_snapshots)').map { |c| c['name'] }
      expect(columns).to include(
        'id', 'git_sha', 'git_branch', 'extracted_at',
        'rails_version', 'ruby_version', 'total_units', 'unit_counts',
        'gemfile_lock_sha', 'schema_sha',
        'units_added', 'units_modified', 'units_deleted'
      )
    end

    it 'enforces unique git_sha' do
      db.execute(<<~SQL)
        INSERT INTO codebase_snapshots (git_sha, extracted_at, total_units) VALUES ('abc123', '2026-01-01T00:00:00Z', 10)
      SQL
      expect do
        db.execute(<<~SQL)
          INSERT INTO codebase_snapshots (git_sha, extracted_at, total_units) VALUES ('abc123', '2026-01-02T00:00:00Z', 20)
        SQL
      end.to raise_error(SQLite3::ConstraintException)
    end

    it 'creates extracted_at index' do
      indexes = db.execute("SELECT name FROM sqlite_master WHERE type='index'").map { |r| r['name'] }
      expect(indexes).to include('idx_snapshots_extracted_at')
    end

    it 'creates branch index' do
      indexes = db.execute("SELECT name FROM sqlite_master WHERE type='index'").map { |r| r['name'] }
      expect(indexes).to include('idx_snapshots_branch')
    end
  end

  describe 'Migration 005: CreateSnapshotUnits' do
    it 'creates codebase_snapshot_units table' do
      tables = db.execute("SELECT name FROM sqlite_master WHERE type='table'").map { |r| r['name'] }
      expect(tables).to include('codebase_snapshot_units')
    end

    it 'has expected columns' do
      columns = db.execute('PRAGMA table_info(codebase_snapshot_units)').map { |c| c['name'] }
      expect(columns).to include(
        'id', 'snapshot_id', 'identifier', 'unit_type',
        'source_hash', 'metadata_hash', 'dependencies_hash'
      )
    end

    it 'enforces unique (snapshot_id, identifier)' do
      db.execute(<<~SQL)
        INSERT INTO codebase_snapshots (git_sha, extracted_at, total_units) VALUES ('abc123', '2026-01-01T00:00:00Z', 10)
      SQL
      snapshot_id = db.get_first_value('SELECT id FROM codebase_snapshots WHERE git_sha = ?', ['abc123'])

      db.execute(<<~SQL, [snapshot_id])
        INSERT INTO codebase_snapshot_units (snapshot_id, identifier, unit_type) VALUES (?, 'User', 'model')
      SQL
      expect do
        db.execute(<<~SQL, [snapshot_id])
          INSERT INTO codebase_snapshot_units (snapshot_id, identifier, unit_type) VALUES (?, 'User', 'model')
        SQL
      end.to raise_error(SQLite3::ConstraintException)
    end

    it 'creates identifier index' do
      indexes = db.execute("SELECT name FROM sqlite_master WHERE type='index'").map { |r| r['name'] }
      expect(indexes).to include('idx_snapshot_units_identifier')
    end

    it 'creates snapshot index' do
      indexes = db.execute("SELECT name FROM sqlite_master WHERE type='index'").map { |r| r['name'] }
      expect(indexes).to include('idx_snapshot_units_snapshot')
    end
  end

  describe 'Migrator integration' do
    it 'records versions 4 and 5 as applied' do
      migrator = CodebaseIndex::Db::Migrator.new(connection: db)
      expect(migrator.schema_version.applied_versions).to include(4, 5)
    end

    it 'is idempotent' do
      migrator = CodebaseIndex::Db::Migrator.new(connection: db)
      expect(migrator.migrate!).to eq([])
    end
  end
end
