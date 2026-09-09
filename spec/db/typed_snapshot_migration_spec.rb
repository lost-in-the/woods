# frozen_string_literal: true

require 'spec_helper'
require 'sqlite3'
require 'woods/db/migrator'

RSpec.describe Woods::Db::Migrations::TypedSnapshotUnits do
  it 'preserves version-six records and tolerates retry before the ledger advances' do
    db = SQLite3::Database.new(':memory:')
    Woods::Db::Migrator::MIGRATIONS.first(6).each { |migration| migration.up(db) }
    db.execute("INSERT INTO woods_snapshots (git_sha, extracted_at) VALUES ('abc', '2026-01-01')")
    db.execute("INSERT INTO woods_snapshot_units (snapshot_id, identifier, unit_type) VALUES (1, 'reports', 'factory')")
    2.times { described_class.up(db) }
    db.execute('INSERT INTO woods_snapshot_units (snapshot_id, identifier, unit_type) ' \
               "VALUES (1, 'reports', 'database_view')")
    expect(db.execute('SELECT identifier, unit_type FROM woods_snapshot_units ORDER BY id'))
      .to eq([%w[reports factory], %w[reports database_view]])
  ensure
    db&.close
  end
end
