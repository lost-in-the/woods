# frozen_string_literal: true

require 'spec_helper'
require 'woods'
require 'woods/extractor'
require 'sqlite3'
require 'woods/db/migrator'
require 'woods/temporal/snapshot_store'
require 'woods/temporal/json_snapshot_store'

RSpec.describe Woods::Extractor, 'snapshot unit types' do
  include_context 'isolated Woods runtime'

  let(:output_dir) { Dir.mktmpdir('woods_snapshot_types') }
  let(:extractor) { described_class.new(output_dir: output_dir) }
  let(:results) do
    {
      models: [unit(:model, 'Report')],
      graphql: [unit(:graphql_type, 'Types::Report'), unit(:graphql_query, 'Types::Query')],
      rails_source: [unit(:rails_source, 'ActiveRecord::Base'), unit(:gem_source, 'Example::Client')]
    }
  end

  before do
    stub_const('Rails', double('Rails', root: Pathname.new(output_dir), logger: double('Logger').as_null_object))
    Woods.configuration.enable_snapshots = true
  end

  after { FileUtils.rm_rf(output_dir) }

  def unit(type, identifier)
    Woods::ExtractedUnit.new(type: type, identifier: identifier, file_path: nil).tap do |extracted|
      extracted.source_code = "# #{identifier}"
    end
  end

  def capture(sha, results)
    File.write(File.join(output_dir, 'manifest.json'),
               JSON.generate(git_sha: sha, extracted_at: "2026-01-0#{sha == 'bbb' ? 2 : 3}T00:00:00Z"))
    extractor.instance_variable_set(:@results, results)
    extractor.send(:capture_snapshot)
  end

  %i[sqlite json].each do |backend|
    context "with #{backend} storage" do
      let(:db) do
        SQLite3::Database.new(':memory:').tap do |connection|
          connection.results_as_hash = true
          Woods::Db::Migrator.new(connection: connection).migrate!
        end
      end
      let(:store) do
        if backend == :sqlite
          Woods::Temporal::SnapshotStore.new(connection: db)
        else
          Woods::Temporal::JsonSnapshotStore.new(dir: output_dir)
        end
      end

      before { allow(extractor).to receive(:build_snapshot_store).and_return(store) }
      after { db.close if backend == :sqlite }

      it 'persists each unit type from mixed extractor families and uses it in diffs' do
        capture('bbb', results)

        results.each_value do |units|
          units.each do |unit|
            expect(store.unit_history(unit.identifier).map { |entry| entry[:unit_type] }).to eq([unit.type.to_s])
          end
        end

        remaining = results.merge(graphql: results[:graphql].first(1), rails_source: results[:rails_source].first(1))
        capture('ccc', remaining)

        expect(store.diff('bbb', 'ccc')).to eq(
          added: [], modified: [],
          deleted: [{ identifier: 'Types::Query', unit_type: 'graphql_query' },
                    { identifier: 'Example::Client', unit_type: 'gem_source' }]
        )
        expect(store.unit_history('Types::Report').map { |entry| entry[:changed] }).to eq([false, true])
      end

      it 'leaves retained historical family types unchanged when capturing new unit types' do
        store.capture({ 'git_sha' => 'aaa', 'extracted_at' => '2026-01-01T00:00:00Z' },
                      [{ 'identifier' => 'Types::Report', 'type' => 'graphql', 'source_hash' => 'legacy' }])
        historical = if backend == :sqlite
                       db.execute('SELECT * FROM woods_snapshot_units')
                     else
                       File.binread(File.join(output_dir, 'snapshots/aaa.json'))
                     end

        capture('bbb', results)

        retained = if backend == :sqlite
                     db.execute('SELECT * FROM woods_snapshot_units WHERE snapshot_id = ?', [store.find('aaa')[:id]])
                   else
                     File.binread(File.join(output_dir, 'snapshots/aaa.json'))
                   end
        expect(retained).to eq(historical)
        expect(store.unit_history('Types::Report').map { |entry| entry[:unit_type] }).to eq(%w[graphql_type graphql])
        expect(store.diff('aaa', 'bbb')[:deleted]).to eq([{ identifier: 'Types::Report', unit_type: 'graphql' }])
      end

      it 'retains coexisting types with the same identifier within one extractor family' do
        units = [unit(:rails_source, 'Example::Shared'), unit(:gem_source, 'Example::Shared')]
        capture('bbb', { rails_source: units })

        expect(store.unit_history('Example::Shared').map { |entry| entry[:unit_type] })
          .to contain_exactly('rails_source', 'gem_source')

        capture('ccc', { rails_source: units.last(1) })

        expect(store.diff('bbb', 'ccc')).to eq(
          added: [], modified: [], deleted: [{ identifier: 'Example::Shared', unit_type: 'rails_source' }]
        )
      end
    end
  end
end
