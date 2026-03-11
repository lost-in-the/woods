# frozen_string_literal: true

require 'spec_helper'
require 'woods/db/migrator'
require 'sqlite3'

RSpec.describe Woods::Db::Migrator do
  let(:db) { SQLite3::Database.new(':memory:') }

  subject(:migrator) { described_class.new(connection: db) }

  describe '#migrate!' do
    it 'creates woods_units table' do
      migrator.migrate!
      tables = db.execute("SELECT name FROM sqlite_master WHERE type='table'").flatten
      expect(tables).to include('woods_units')
    end

    it 'creates woods_edges table' do
      migrator.migrate!
      tables = db.execute("SELECT name FROM sqlite_master WHERE type='table'").flatten
      expect(tables).to include('woods_edges')
    end

    it 'creates woods_embeddings table' do
      migrator.migrate!
      tables = db.execute("SELECT name FROM sqlite_master WHERE type='table'").flatten
      expect(tables).to include('woods_embeddings')
    end

    it 'records applied versions' do
      migrator.migrate!
      expect(migrator.schema_version.applied_versions).to eq([1, 2, 3, 4, 5])
    end

    it 'is idempotent — skips already-applied migrations' do
      migrator.migrate!
      # Should not raise on second run
      migrator.migrate!
      expect(migrator.schema_version.applied_versions).to eq([1, 2, 3, 4, 5])
    end

    it 'returns list of newly applied version numbers' do
      result = migrator.migrate!
      expect(result).to eq([1, 2, 3, 4, 5])

      # Second run applies nothing
      result2 = migrator.migrate!
      expect(result2).to eq([])
    end
  end

  describe '#pending_versions' do
    it 'returns all versions when none applied' do
      expect(migrator.pending_versions).to eq([1, 2, 3, 4, 5])
    end

    it 'returns only unapplied versions' do
      migrator.migrate!
      expect(migrator.pending_versions).to eq([])
    end
  end

  describe 'woods_units schema' do
    before { migrator.migrate! }

    it 'has expected columns' do
      columns = db.execute('PRAGMA table_info(woods_units)').map { |c| c[1] }
      expect(columns).to include(
        'id', 'unit_type', 'identifier', 'namespace',
        'file_path', 'source_code', 'source_hash', 'metadata'
      )
    end

    it 'enforces unique identifier' do
      insert_sql = <<~SQL.chomp
        INSERT INTO woods_units (unit_type, identifier, file_path)
        VALUES ('model', 'User', 'app/models/user.rb')
      SQL
      db.execute(insert_sql)
      expect do
        db.execute(insert_sql)
      end.to raise_error(SQLite3::ConstraintException)
    end
  end

  describe 'woods_edges schema' do
    before { migrator.migrate! }

    it 'has expected columns' do
      columns = db.execute('PRAGMA table_info(woods_edges)').map { |c| c[1] }
      expect(columns).to include('id', 'source_id', 'target_id', 'relationship', 'via')
    end
  end
end
