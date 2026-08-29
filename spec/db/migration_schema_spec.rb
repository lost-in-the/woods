# frozen_string_literal: true

require 'spec_helper'
require 'woods/db/migrator'
require 'sqlite3'

# Column-level assertions for the schema migrations 001-003 and the 006 table
# rename. (004/005 have their own file, snapshot_migration_spec.rb.) The
# migrator runs every pending migration in order against one connection, so a
# broken migration surfaces here as a missing table, column, or index.
RSpec.describe 'Core migrations' do
  let(:db) { SQLite3::Database.new(':memory:') }

  before do
    db.results_as_hash = true
    Woods::Db::Migrator.new(connection: db).migrate!
  end

  def table_names
    db.execute("SELECT name FROM sqlite_master WHERE type='table'").map { |r| r['name'] }
  end

  def column_names(table)
    db.execute("PRAGMA table_info(#{table})").map { |c| c['name'] }
  end

  def index_names
    db.execute("SELECT name FROM sqlite_master WHERE type='index'").map { |r| r['name'] }
  end

  describe 'Migration 001: CreateUnits' do
    it 'creates woods_units' do
      expect(table_names).to include('woods_units')
    end

    it 'has expected columns' do
      expect(column_names('woods_units')).to contain_exactly(
        'id', 'unit_type', 'identifier', 'namespace', 'file_path',
        'source_code', 'source_hash', 'metadata', 'created_at', 'updated_at'
      )
    end

    it 'enforces unique identifier' do
      db.execute(
        "INSERT INTO woods_units (unit_type, identifier, file_path) VALUES ('model', 'User', 'app/models/user.rb')"
      )
      expect do
        db.execute(
          "INSERT INTO woods_units (unit_type, identifier, file_path) VALUES ('model', 'User', 'elsewhere.rb')"
        )
      end.to raise_error(SQLite3::ConstraintException)
    end

    it 'creates the unit_type and file_path indexes' do
      expect(index_names).to include('idx_woods_units_type', 'idx_woods_units_file_path')
    end
  end

  describe 'Migration 002: CreateEdges' do
    it 'creates woods_edges' do
      expect(table_names).to include('woods_edges')
    end

    it 'has expected columns' do
      expect(column_names('woods_edges')).to contain_exactly(
        'id', 'source_id', 'target_id', 'relationship', 'via', 'created_at'
      )
    end

    it 'creates the source and target indexes' do
      expect(index_names).to include('idx_woods_edges_source', 'idx_woods_edges_target')
    end
  end

  describe 'Migration 003: CreateEmbeddings' do
    it 'creates woods_embeddings' do
      expect(table_names).to include('woods_embeddings')
    end

    it 'has expected columns' do
      expect(column_names('woods_embeddings')).to contain_exactly(
        'id', 'unit_id', 'chunk_type', 'embedding', 'content_hash', 'dimensions', 'created_at'
      )
    end

    it 'creates the unit and content_hash indexes' do
      expect(index_names).to include('idx_woods_embeddings_unit', 'idx_woods_embeddings_hash')
    end
  end

  # The gem rename. Fresh installs never had codebase_* tables (the rename
  # guard skips absent ones); legacy databases must come across with their
  # rows intact.
  describe 'Migration 006: RenameTables' do
    it 'leaves no legacy codebase tables on a fresh install' do
      expect(table_names.grep(/\Acodebase_/)).to be_empty
    end

    it 'renames legacy codebase_units to woods_units, preserving data' do
      legacy_db = SQLite3::Database.new(':memory:')
      version = Woods::Db::SchemaVersion.new(connection: legacy_db)
      version.ensure_table!
      (1..5).each { |v| version.record_version(v) }
      legacy_db.execute(<<~SQL)
        CREATE TABLE codebase_units (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          unit_type TEXT NOT NULL,
          identifier TEXT NOT NULL
        )
      SQL
      legacy_db.execute("INSERT INTO codebase_units (unit_type, identifier) VALUES ('model', 'LegacyUser')")

      applied = Woods::Db::Migrator.new(connection: legacy_db).migrate!

      expect(applied).to eq([6])
      expect(
        legacy_db.get_first_value('SELECT identifier FROM woods_units WHERE id = 1')
      ).to eq('LegacyUser')
      expect(
        legacy_db.execute("SELECT name FROM sqlite_master WHERE type='table' AND name='codebase_units'")
      ).to be_empty
    ensure
      legacy_db&.close
    end
  end

  describe 'Migrator integration' do
    it 'records every migration version as applied' do
      migrator = Woods::Db::Migrator.new(connection: db)
      expect(migrator.schema_version.applied_versions).to contain_exactly(1, 2, 3, 4, 5, 6)
    end

    it 'is idempotent' do
      migrator = Woods::Db::Migrator.new(connection: db)
      expect(migrator.migrate!).to eq([])
    end
  end
end
