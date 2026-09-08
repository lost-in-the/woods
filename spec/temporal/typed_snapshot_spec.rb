# frozen_string_literal: true

require 'spec_helper'
require 'woods'
require 'sqlite3'
require 'woods/db/migrator'
require 'woods/temporal/snapshot_store'
require 'woods/temporal/json_snapshot_store'

RSpec.describe 'Typed snapshot identities' do
  it 'reads legacy JSON snapshots alongside newly typed snapshots' do
    Dir.mktmpdir do |dir|
      store = Woods::Temporal::JsonSnapshotStore.new(dir: dir)
      legacy = { git_sha: 'aaa', extracted_at: '2026-01-01T00:00:00Z',
                 units: { reports: { unit_type: 'factory', source_hash: 'same' } } }
      File.write(File.join(dir, 'snapshots/aaa.json'), JSON.generate(legacy))
      store.capture({ 'git_sha' => 'bbb', 'extracted_at' => '2026-01-02T00:00:00Z' },
                    [{ 'identifier' => 'reports', 'type' => 'factory', 'source_hash' => 'same' }])
      expect(store.diff('aaa', 'bbb')[:deleted]).to be_empty
      expect(store.diff('aaa', 'bbb')[:added]).to be_empty
      expect(store.unit_history('reports').map { |entry| entry[:changed] }).to eq([false, true])
    end
  end

  %i[sqlite json].each do |backend|
    it "preserves and compares coexisting types on #{backend}" do
      Dir.mktmpdir do |dir|
        db = SQLite3::Database.new(':memory:')
        db.results_as_hash = true
        Woods::Db::Migrator.new(connection: db).migrate!
        store = if backend == :sqlite
                  Woods::Temporal::SnapshotStore.new(connection: db)
                else
                  Woods::Temporal::JsonSnapshotStore.new(dir: dir)
                end
        units = %w[factory database_view].map do |type|
          { 'identifier' => 'reports', 'type' => type, 'source_hash' => type }
        end
        store.capture({ 'git_sha' => 'aaa', 'extracted_at' => '2026-01-01T00:00:00Z' }, units)
        store.capture({ 'git_sha' => 'bbb', 'extracted_at' => '2026-01-02T00:00:00Z' }, [units.last])
        expect(store.diff('aaa',
                          'bbb')).to eq(added: [], modified: [],
                                        deleted: [{ identifier: 'reports', unit_type: 'factory' }])
        history = store.unit_history('reports')
        expect(history.count).to eq(3)
        expect(history.find { |entry| entry[:git_sha] == 'bbb' }[:changed]).to be(false)
      ensure
        db&.close
      end
    end
  end
end
