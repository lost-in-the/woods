# frozen_string_literal: true

require 'spec_helper'
require 'sqlite3'
require 'woods/db/migrator'
require 'woods/temporal/snapshot_store'
require 'woods/temporal/json_snapshot_store'
require 'woods/mcp/server'

RSpec.describe 'Snapshot diff facets' do
  %i[sqlite json].each do |backend|
    context "with #{backend} snapshots" do
      around do |example|
        Dir.mktmpdir('woods-snapshot-facets') do |dir|
          @db = SQLite3::Database.new(':memory:')
          @db.results_as_hash = true
          Woods::Db::Migrator.new(connection: @db).migrate!
          @store = if backend == :sqlite
                     Woods::Temporal::SnapshotStore.new(connection: @db)
                   else
                     Woods::Temporal::JsonSnapshotStore.new(dir: dir)
                   end
          example.run
        ensure
          @db&.close
        end
      end

      let(:unit) do
        { identifier: 'Report', type: 'model', source_hash: 's1', metadata_hash: 'm1', dependencies_hash: 'd1' }
      end

      def capture_pair(before, after)
        @store.capture({ git_sha: 'aaa', extracted_at: '2026-01-01T00:00:00Z' }, before)
        @store.capture({ git_sha: 'bbb', extracted_at: '2026-01-02T00:00:00Z' }, after)
      end

      [%i[source], %i[metadata], %i[dependencies], %i[source metadata], %i[source dependencies],
       %i[metadata dependencies], %i[source metadata dependencies]].each do |facets|
        it "reports only #{facets.join(', ')} in deterministic order" do
          changes = facets.to_h { |facet| [:"#{facet}_hash", 'changed'] }
          capture_pair([unit], [unit.merge(changes)])

          expect(@store.diff('aaa', 'bbb')).to eq(
            added: [], deleted: [],
            modified: [{ identifier: 'Report', unit_type: 'model', facets: facets }]
          )
          expect(@store.diff('bbb', 'aaa')[:modified]).to eq(
            [{ identifier: 'Report', unit_type: 'model', facets: facets }]
          )
          expect(@store.find('bbb')).to include(units_added: 0, units_modified: 1, units_deleted: 0)
        end
      end

      it 'leaves unchanged units and added/deleted entries unaffected' do
        capture_pair([unit, unit.merge(identifier: 'Removed')], [unit, unit.merge(identifier: 'Added')])

        expect(@store.diff('aaa', 'bbb')).to eq(
          added: [{ identifier: 'Added', unit_type: 'model' }], modified: [],
          deleted: [{ identifier: 'Removed', unit_type: 'model' }]
        )
        expect(@store.diff('aaa', 'aaa')).to eq(added: [], modified: [], deleted: [])
        expect(@store.find('bbb')).to include(units_added: 1, units_modified: 0, units_deleted: 1)
      end

      it 'compares facets separately for units sharing an identifier across types' do
        other = unit.merge(type: 'service')
        capture_pair([unit, other], [unit.merge(metadata_hash: 'm2'), other.merge(dependencies_hash: 'd2')])

        expect(@store.diff('aaa', 'bbb')[:modified]).to contain_exactly(
          { identifier: 'Report', unit_type: 'model', facets: [:metadata] },
          { identifier: 'Report', unit_type: 'service', facets: [:dependencies] }
        )
      end

      it 'treats absent legacy hashes as nil and reports hashes becoming available or absent' do
        legacy = unit.except(:source_hash, :metadata_hash, :dependencies_hash)
        capture_pair([legacy], [legacy.merge(source_hash: nil, metadata_hash: nil, dependencies_hash: nil)])
        expect(@store.diff('aaa', 'bbb')[:modified]).to be_empty

        @store.capture({ git_sha: 'bbb', extracted_at: '2026-01-02T00:00:00Z' }, [unit])
        expected = [{ identifier: 'Report', unit_type: 'model', facets: %i[source metadata dependencies] }]
        expect(@store.diff('aaa', 'bbb')[:modified]).to eq(expected)
        expect(@store.diff('bbb', 'aaa')[:modified]).to eq(expected)
      end

      it 'exposes facets as JSON strings in snapshot_diff details with existing counts' do
        capture_pair([unit], [unit.merge(source_hash: 's2', dependencies_hash: 'd2')])
        server = Woods::MCP::Server.build(
          index_dir: File.expand_path('../fixtures/woods', __dir__), snapshot_store: @store
        )
        tool = server.instance_variable_get(:@tools).fetch('snapshot_diff')
        response = tool.call(sha_a: 'aaa', sha_b: 'bbb', server_context: {})
        data = JSON.parse(response.content.first[:text])

        expect(data).to include('sha_a' => 'aaa', 'sha_b' => 'bbb', 'added' => 0, 'modified' => 1, 'deleted' => 0)
        expect(data.fetch('details')).to eq(
          'added' => [], 'deleted' => [],
          'modified' => [{ 'identifier' => 'Report', 'unit_type' => 'model', 'facets' => %w[source dependencies] }]
        )
      end
    end
  end
end
