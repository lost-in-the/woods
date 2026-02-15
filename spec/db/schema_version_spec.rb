# frozen_string_literal: true

require 'spec_helper'
require 'codebase_index/db/schema_version'
require 'sqlite3'

RSpec.describe CodebaseIndex::Db::SchemaVersion do
  let(:db) { SQLite3::Database.new(':memory:') }

  subject(:schema_version) { described_class.new(connection: db) }

  describe '#ensure_table!' do
    it 'creates the schema_migrations table' do
      schema_version.ensure_table!
      sql = "SELECT name FROM sqlite_master WHERE type='table' " \
            "AND name='codebase_index_schema_migrations'"
      result = db.execute(sql)
      expect(result).not_to be_empty
    end

    it 'is idempotent' do
      schema_version.ensure_table!
      schema_version.ensure_table!
      sql = "SELECT name FROM sqlite_master WHERE type='table' " \
            "AND name='codebase_index_schema_migrations'"
      result = db.execute(sql)
      expect(result.size).to eq(1)
    end
  end

  describe '#applied_versions' do
    before { schema_version.ensure_table! }

    it 'returns empty array when no migrations applied' do
      expect(schema_version.applied_versions).to eq([])
    end

    it 'returns applied version numbers sorted' do
      schema_version.record_version(2)
      schema_version.record_version(1)
      expect(schema_version.applied_versions).to eq([1, 2])
    end
  end

  describe '#record_version' do
    before { schema_version.ensure_table! }

    it 'records a version number' do
      schema_version.record_version(1)
      expect(schema_version.applied_versions).to include(1)
    end

    it 'does not duplicate versions' do
      schema_version.record_version(1)
      schema_version.record_version(1)
      expect(schema_version.applied_versions.count(1)).to eq(1)
    end
  end

  describe '#applied?' do
    before { schema_version.ensure_table! }

    it 'returns true for applied versions' do
      schema_version.record_version(1)
      expect(schema_version.applied?(1)).to be true
    end

    it 'returns false for unapplied versions' do
      expect(schema_version.applied?(99)).to be false
    end
  end

  describe '#current_version' do
    before { schema_version.ensure_table! }

    it 'returns 0 when no migrations applied' do
      expect(schema_version.current_version).to eq(0)
    end

    it 'returns the highest applied version' do
      schema_version.record_version(1)
      schema_version.record_version(3)
      expect(schema_version.current_version).to eq(3)
    end
  end
end
