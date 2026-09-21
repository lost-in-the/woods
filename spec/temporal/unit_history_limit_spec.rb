# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'sqlite3'
require 'woods/db/migrator'
require 'woods/temporal/snapshot_store'
require 'woods/temporal/json_snapshot_store'

RSpec.describe 'Temporal history limits across storage adapters' do
  it 'limits matching records across gaps and deletion, with JSON and SQLite parity' do
    Dir.mktmpdir('woods_history_limit') do |directory|
      db = SQLite3::Database.new(':memory:')
      db.results_as_hash = true
      Woods::Db::Migrator.new(connection: db).migrate!
      stores = [
        Woods::Temporal::JsonSnapshotStore.new(dir: directory, retention: 10),
        Woods::Temporal::SnapshotStore.new(connection: db)
      ]
      records = [%w[aaa old], ['bbb', nil], %w[ccc new], ['ddd', nil], ['eee', nil]]
      stores.each do |store|
        records.each_with_index do |(sha, hash), index|
          manifest = { git_sha: sha, extracted_at: "2026-01-0#{index + 1}T00:00:00Z" }
          units = hash ? [{ identifier: 'Gone', type: 'model', source_hash: hash }] : []
          store.capture(manifest, units)
        end
        expect(store.unit_history('Gone', limit: 1).map { |entry| entry[:git_sha] }).to eq(['ccc'])
        expect(store.unit_history('Gone', limit: 2).map { |entry| entry[:git_sha] }).to eq(%w[ccc aaa])
        expect(store.unit_history('Gone', limit: 0)).to eq([])
        expect(store.unit_history('Unknown', limit: 1)).to eq([])
      end
      keys = %i[git_sha source_hash changed]
      expect(stores.first.unit_history('Gone', limit: 2).map { |row| row.slice(*keys) })
        .to eq(stores.last.unit_history('Gone', limit: 2).map { |row| row.slice(*keys) })
    ensure
      db&.close
    end
  end
end
