# frozen_string_literal: true

require 'spec_helper'
require 'codebase_index'
require 'codebase_index/dependency_graph'
require 'codebase_index/mcp/server'

RSpec.describe 'Snapshot MCP tools' do
  let(:fixture_dir) { File.expand_path('../fixtures/codebase_index', __dir__) }

  # Helpers (same as server_spec.rb)
  def call_tool(server, tool_name, **args)
    tools = server.instance_variable_get(:@tools)
    tool_class = tools[tool_name]
    raise "Tool not found: #{tool_name}" unless tool_class

    tool_class.call(**args, server_context: {})
  end

  def response_text(response)
    response.content.first[:text]
  end

  def parse_response(response)
    JSON.parse(response_text(response))
  end

  # ── Without snapshot store ────────────────────────────────────────

  describe 'without snapshot store configured' do
    let(:server) { CodebaseIndex::MCP::Server.build(index_dir: fixture_dir) }

    it 'list_snapshots returns not configured message' do
      response = call_tool(server, 'list_snapshots')
      expect(response_text(response)).to include('not configured')
    end

    it 'snapshot_diff returns not configured message' do
      response = call_tool(server, 'snapshot_diff', sha_a: 'abc', sha_b: 'def')
      expect(response_text(response)).to include('not configured')
    end

    it 'unit_history returns not configured message' do
      response = call_tool(server, 'unit_history', identifier: 'User')
      expect(response_text(response)).to include('not configured')
    end

    it 'snapshot_detail returns not configured message' do
      response = call_tool(server, 'snapshot_detail', git_sha: 'abc')
      expect(response_text(response)).to include('not configured')
    end
  end

  # ── With snapshot store configured ────────────────────────────────

  describe 'with snapshot store configured' do
    let(:snapshot_store) do
      instance_double('CodebaseIndex::Temporal::SnapshotStore')
    end

    let(:server) do
      CodebaseIndex::MCP::Server.build(index_dir: fixture_dir, snapshot_store: snapshot_store)
    end

    describe 'tool: list_snapshots' do
      it 'returns snapshot list' do
        snapshot = {
          git_sha: 'aaa111',
          extracted_at: '2026-01-01T10:00:00Z',
          total_units: 42
        }
        allow(snapshot_store).to receive(:list)
          .with(limit: 20, branch: nil)
          .and_return([snapshot])

        response = call_tool(server, 'list_snapshots')
        data = parse_response(response)
        expect(data['snapshot_count']).to eq(1)
        expect(data['snapshots'].first['git_sha']).to eq('aaa111')
      end

      it 'passes limit and branch params' do
        allow(snapshot_store).to receive(:list).with(limit: 5, branch: 'main').and_return([])

        call_tool(server, 'list_snapshots', limit: 5, branch: 'main')
        expect(snapshot_store).to have_received(:list).with(limit: 5, branch: 'main')
      end
    end

    describe 'tool: snapshot_diff' do
      it 'returns diff with added/modified/deleted' do
        diff_result = {
          added: [{ identifier: 'NewModel', unit_type: 'model' }],
          modified: [{ identifier: 'User', unit_type: 'model' }],
          deleted: []
        }
        allow(snapshot_store).to receive(:diff)
          .with('aaa', 'bbb').and_return(diff_result)

        response = call_tool(server, 'snapshot_diff', sha_a: 'aaa', sha_b: 'bbb')
        data = parse_response(response)
        expect(data['added']).to eq(1)
        expect(data['modified']).to eq(1)
        expect(data['deleted']).to eq(0)
        expect(data['details']['added'].first['identifier']).to eq('NewModel')
      end
    end

    describe 'tool: unit_history' do
      it 'returns history entries for a unit' do
        history = [
          { git_sha: 'bbb222', extracted_at: '2026-01-02T10:00:00Z',
            source_hash: 'h2', changed: true },
          { git_sha: 'aaa111', extracted_at: '2026-01-01T10:00:00Z',
            source_hash: 'h1', changed: true }
        ]
        allow(snapshot_store).to receive(:unit_history)
          .with('User', limit: 20).and_return(history)

        response = call_tool(server, 'unit_history', identifier: 'User')
        data = parse_response(response)
        expect(data['identifier']).to eq('User')
        expect(data['versions']).to eq(2)
        expect(data['history'].first['git_sha']).to eq('bbb222')
      end

      it 'passes limit param' do
        allow(snapshot_store).to receive(:unit_history).with('User', limit: 5).and_return([])

        call_tool(server, 'unit_history', identifier: 'User', limit: 5)
        expect(snapshot_store).to have_received(:unit_history).with('User', limit: 5)
      end
    end

    describe 'tool: snapshot_detail' do
      it 'returns full snapshot metadata' do
        allow(snapshot_store).to receive(:find).with('aaa111').and_return({
                                                                            git_sha: 'aaa111',
                                                                            git_branch: 'main',
                                                                            extracted_at: '2026-01-01T10:00:00Z',
                                                                            total_units: 42,
                                                                            units_added: 5,
                                                                            units_modified: 3,
                                                                            units_deleted: 1
                                                                          })

        response = call_tool(server, 'snapshot_detail', git_sha: 'aaa111')
        data = parse_response(response)
        expect(data['git_sha']).to eq('aaa111')
        expect(data['total_units']).to eq(42)
      end

      it 'returns not found for unknown SHA' do
        allow(snapshot_store).to receive(:find).with('unknown').and_return(nil)

        response = call_tool(server, 'snapshot_detail', git_sha: 'unknown')
        expect(response_text(response)).to include('not found')
      end
    end
  end
end
