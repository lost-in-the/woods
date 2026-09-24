# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'sqlite3'
require 'woods'
require 'woods/mcp/server'
require 'woods/temporal/json_snapshot_store'
require 'woods/temporal/snapshot_store'
require 'woods/db/migrator'

RSpec.describe 'Index MCP missing target responses' do
  let(:index_dir) { Dir.mktmpdir('woods-missing-targets') }
  let(:fixture_dir) { File.expand_path('../fixtures/woods', __dir__) }

  before { FileUtils.cp_r(File.join(fixture_dir, '.'), index_dir) }
  after { FileUtils.rm_rf(index_dir) }

  def call_tool(server, name, **arguments)
    response = server.handle_json(JSON.generate(jsonrpc: '2.0', id: 1, method: 'tools/call',
                                                params: { name: name, arguments: arguments }))
    JSON.parse(response).fetch('result')
  end

  it 'distinguishes an unknown flow unit from a known unit with no operations' do
    dir = File.join(index_dir, 'poros')
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, '_index.json'), JSON.generate([{ identifier: 'NoOperations' }]))
    filename = Woods::MCP::IndexReader.new(index_dir).send(:unit_filename, 'NoOperations')
    File.write(File.join(dir, filename), JSON.generate(identifier: 'NoOperations', type: 'poro',
                                                       source_code: 'class NoOperations; end', metadata: {}))
    server = Woods::MCP::Server.build(index_dir: index_dir, response_format: :json, warmup: false)

    missing = call_tool(server, 'trace_flow', entry_point: 'Missing#call')
    expect(missing).to include('isError' => true)
    expect(missing.fetch('_meta')).to include('error_code' => 'not_found')
    known = call_tool(server, 'trace_flow', entry_point: 'NoOperations')
    expect(known['isError']).not_to be(true)
    steps = JSON.parse(known.fetch('content').first.fetch('text')).fetch('steps')
    expect(steps.flat_map { |step| step.fetch('operations') }).to be_empty
  end

  %i[json sqlite].each do |backend|
    it "distinguishes missing, malformed and valid identical snapshots with #{backend}" do
      if backend == :sqlite
        database = SQLite3::Database.new(':memory:')
        database.results_as_hash = true
        Woods::Db::Migrator.new(connection: database).migrate!
        store = Woods::Temporal::SnapshotStore.new(connection: database)
      else
        store = Woods::Temporal::JsonSnapshotStore.new(dir: index_dir)
      end
      sha = 'a' * 40
      store.capture({ git_sha: sha, extracted_at: '2026-09-24T00:00:00Z', total_units: 0, counts: {} }, [])
      server = Woods::MCP::Server.build(index_dir: index_dir, snapshot_store: store, warmup: false)
      { 'b' * 40 => 'not_found', 'aaa' => 'not_found', '../private' => 'invalid_params' }.each do |target, code|
        result = call_tool(server, 'snapshot_diff', sha_a: sha, sha_b: target)
        expect(result).to include('isError' => true)
        expect(result.fetch('_meta')).to include('error_code' => code)
      end
      same = call_tool(server, 'snapshot_diff', sha_a: sha, sha_b: sha)
      expect(same['isError']).not_to be(true)
      expect(JSON.parse(same.fetch('content').first.fetch('text')))
        .to include('added' => 0, 'modified' => 0, 'deleted' => 0)
    ensure
      database&.close
    end
  end
end
