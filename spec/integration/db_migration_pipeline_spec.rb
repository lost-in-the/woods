# frozen_string_literal: true

require 'spec_helper'
require 'sqlite3'
require 'woods/db/migrator'

RSpec.describe 'DB Migration Pipeline Integration', :integration do
  let(:db) { SQLite3::Database.new(':memory:') }

  describe 'SchemaVersion' do
    let(:schema_version) { Woods::Db::SchemaVersion.new(connection: db) }

    before { schema_version.ensure_table! }

    it 'creates the schema_migrations table' do
      tables = db.execute("SELECT name FROM sqlite_master WHERE type='table'")
      table_names = tables.map { |r| r[0] }

      expect(table_names).to include('woods_schema_migrations')
    end

    it 'starts with no applied versions' do
      expect(schema_version.applied_versions).to eq([])
      expect(schema_version.current_version).to eq(0)
    end

    it 'records and retrieves versions' do
      schema_version.record_version(1)
      schema_version.record_version(2)

      expect(schema_version.applied_versions).to eq([1, 2])
      expect(schema_version.current_version).to eq(2)
    end

    it 'checks whether a version is applied' do
      schema_version.record_version(1)

      expect(schema_version.applied?(1)).to be true
      expect(schema_version.applied?(2)).to be false
    end

    it 'handles duplicate version inserts idempotently' do
      schema_version.record_version(1)
      schema_version.record_version(1)

      expect(schema_version.applied_versions).to eq([1])
    end

    it 'is idempotent when called multiple times' do
      schema_version.ensure_table!
      schema_version.ensure_table!

      expect(schema_version.current_version).to eq(0)
    end
  end

  describe 'Migrator' do
    let(:migrator) { Woods::Db::Migrator.new(connection: db) }

    it 'starts with all migrations pending' do
      expect(migrator.pending_versions).to eq([1, 2, 3, 4, 5])
    end

    it 'runs all 5 migrations' do
      applied = migrator.migrate!

      expect(applied).to eq([1, 2, 3, 4, 5])
    end

    it 'creates the woods_units table' do
      migrator.migrate!

      tables = db.execute("SELECT name FROM sqlite_master WHERE type='table' AND name='woods_units'")
      expect(tables).not_to be_empty
    end

    it 'creates the woods_edges table' do
      migrator.migrate!

      tables = db.execute("SELECT name FROM sqlite_master WHERE type='table' AND name='woods_edges'")
      expect(tables).not_to be_empty
    end

    it 'creates the woods_embeddings table' do
      migrator.migrate!

      tables = db.execute("SELECT name FROM sqlite_master WHERE type='table' AND name='woods_embeddings'")
      expect(tables).not_to be_empty
    end

    it 'records all versions as applied' do
      migrator.migrate!

      expect(migrator.schema_version.applied_versions).to eq([1, 2, 3, 4, 5])
      expect(migrator.schema_version.current_version).to eq(5)
    end

    it 'has no pending migrations after running all' do
      migrator.migrate!

      expect(migrator.pending_versions).to eq([])
    end

    it 'is idempotent — re-running returns empty' do
      migrator.migrate!
      second_run = migrator.migrate!

      expect(second_run).to eq([])
    end
  end

  describe 'full schema validation after migration' do
    before { Woods::Db::Migrator.new(connection: db).migrate! }

    it 'allows inserting and querying a unit' do
      db.execute(
        'INSERT INTO woods_units (unit_type, identifier, file_path, source_code) VALUES (?, ?, ?, ?)',
        ['model', 'User', 'app/models/user.rb', 'class User; end']
      )

      rows = db.execute("SELECT identifier, unit_type FROM woods_units WHERE identifier = 'User'")
      expect(rows.size).to eq(1)
      expect(rows.first).to eq(%w[User model])
    end

    it 'enforces unique identifier constraint' do
      db.execute(
        'INSERT INTO woods_units (unit_type, identifier, file_path) VALUES (?, ?, ?)',
        ['model', 'User', 'app/models/user.rb']
      )

      expect do
        db.execute(
          'INSERT INTO woods_units (unit_type, identifier, file_path) VALUES (?, ?, ?)',
          ['model', 'User', 'app/models/user_duplicate.rb']
        )
      end.to raise_error(SQLite3::ConstraintException)
    end

    it 'allows inserting edges between units' do
      db.execute(
        'INSERT INTO woods_units (unit_type, identifier, file_path) VALUES (?, ?, ?)',
        ['model', 'User', 'app/models/user.rb']
      )
      db.execute(
        'INSERT INTO woods_units (unit_type, identifier, file_path) VALUES (?, ?, ?)',
        ['model', 'Post', 'app/models/post.rb']
      )

      user_id = db.get_first_value("SELECT id FROM woods_units WHERE identifier = 'User'")
      post_id = db.get_first_value("SELECT id FROM woods_units WHERE identifier = 'Post'")

      db.execute(
        'INSERT INTO woods_edges (source_id, target_id, relationship) VALUES (?, ?, ?)',
        [user_id, post_id, 'has_many']
      )

      edges = db.execute('SELECT * FROM woods_edges WHERE source_id = ?', [user_id])
      expect(edges.size).to eq(1)
    end

    it 'allows inserting embeddings for a unit' do
      db.execute(
        'INSERT INTO woods_units (unit_type, identifier, file_path) VALUES (?, ?, ?)',
        ['model', 'User', 'app/models/user.rb']
      )

      unit_id = db.get_first_value("SELECT id FROM woods_units WHERE identifier = 'User'")
      embedding_json = JSON.generate([0.1, 0.2, 0.3])

      db.execute(
        'INSERT INTO woods_embeddings (unit_id, embedding, content_hash, dimensions) VALUES (?, ?, ?, ?)',
        [unit_id, embedding_json, 'abc123', 3]
      )

      rows = db.execute('SELECT * FROM woods_embeddings WHERE unit_id = ?', [unit_id])
      expect(rows.size).to eq(1)
    end

    it 'creates indexes on woods_units' do
      indexes = db.execute("SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='woods_units'")
      index_names = indexes.map { |r| r[0] }

      expect(index_names).to include('idx_woods_units_type')
      expect(index_names).to include('idx_woods_units_file_path')
    end

    it 'creates indexes on woods_edges' do
      indexes = db.execute("SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='woods_edges'")
      index_names = indexes.map { |r| r[0] }

      expect(index_names).to include('idx_woods_edges_source')
      expect(index_names).to include('idx_woods_edges_target')
    end

    it 'creates indexes on woods_embeddings' do
      indexes = db.execute("SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='woods_embeddings'")
      index_names = indexes.map { |r| r[0] }

      expect(index_names).to include('idx_woods_embeddings_unit')
      expect(index_names).to include('idx_woods_embeddings_hash')
    end
  end
end
