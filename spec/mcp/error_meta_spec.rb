# frozen_string_literal: true

require 'spec_helper'
require 'woods'
require 'woods/mcp/server'

# Structured-error contract: every tool that fails with a known condition must
# return a Tool::Response with `error?: true` and a `_meta.error_code`. Agents
# branch on error_code without parsing prose — this suite pins the shape.
RSpec.describe 'MCP tool structured errors' do
  let(:fixture_dir) { File.expand_path('../fixtures/woods', __dir__) }
  let(:server) { Woods::MCP::Server.build(index_dir: fixture_dir) }

  def call_tool(server, tool_name, **args)
    tool = server.instance_variable_get(:@tools)[tool_name]
    tool.call(**args, server_context: {})
  end

  def expect_error(response, code:, config_key: nil)
    expect(response).to be_a(MCP::Tool::Response)
    expect(response.error?).to be(true)
    expect(response.meta).to include(error_code: code)
    expect(response.meta[:config_key]).to eq(config_key) if config_key
  end

  describe 'lookup' do
    it 'returns :not_found with identifier + hint when unit missing' do
      response = call_tool(server, 'lookup', identifier: 'DoesNotExist123')
      expect_error(response, code: :not_found)
      expect(response.meta[:identifier]).to eq('DoesNotExist123')
      expect(response.meta[:hint]).to be_a(String)
      expect(response.meta[:tool]).to eq('lookup')
    end
  end

  describe 'codebase_retrieve' do
    it 'returns :not_configured when no retriever is wired' do
      response = call_tool(server, 'codebase_retrieve', query: 'anything')
      expect_error(response, code: :not_configured, config_key: 'embedding_provider')
      expect(response.meta[:doc_link]).to include('RETRIEVAL_GUIDE')
    end
  end

  describe 'pipeline_extract' do
    # The tool is not registered when operator is nil — that's the "correct
    # cliff-avoidance contract". An explicit operator with a missing
    # component (e.g. no :status_reporter) still registers the tool and
    # returns :not_configured, which we verify elsewhere.
    it 'is not registered when operator is nil' do
      tools = server.instance_variable_get(:@tools)
      expect(tools.keys).not_to include('pipeline_extract')
    end
  end

  describe 'pipeline_repair' do
    it 'returns :unsupported_argument for unknown action when operator present' do
      operator = { pipeline_lock: nil }
      op_server = Woods::MCP::Server.build(index_dir: fixture_dir, operator: operator)
      response = call_tool(op_server, 'pipeline_repair', action: 'nuke_production')
      expect_error(response, code: :unsupported_argument)
      expect(response.meta[:allowed]).to include('clear_locks', 'reset_cooldowns')
    end
  end

  describe 'retrieval_rate' do
    it 'is not registered when feedback_store is nil' do
      tools = server.instance_variable_get(:@tools)
      expect(tools.keys).not_to include('retrieval_rate')
    end
  end

  describe 'list_snapshots' do
    it 'is not registered when snapshot_store is nil' do
      tools = server.instance_variable_get(:@tools)
      expect(tools.keys).not_to include('list_snapshots')
    end
  end

  describe 'snapshot_detail' do
    it 'returns :not_found with git_sha when snapshot missing but store present' do
      store = Class.new { def find(_sha) = nil }.new
      server_with_store = Woods::MCP::Server.build(index_dir: fixture_dir, snapshot_store: store)
      response = call_tool(server_with_store, 'snapshot_detail', git_sha: 'deadbee')
      expect_error(response, code: :not_found)
      expect(response.meta[:git_sha]).to eq('deadbee')
    end
  end

  describe 'notion_sync' do
    before do
      config = Struct.new(:notion_api_token, :notion_database_ids,
                          :embedding_model, :embedding_provider, :vector_store,
                          :session_tracer_enabled, :enable_snapshots,
                          :console_mcp_enabled, :session_store, :context_format).new(
                            nil, {}, nil, nil, nil, false, false, false, nil, :markdown
                          )
      Woods.configuration = config
    end

    after { Woods.configuration = nil }

    it 'is not registered when notion_api_token is missing' do
      srv = Woods::MCP::Server.build(index_dir: fixture_dir)
      tools = srv.instance_variable_get(:@tools)
      expect(tools.keys).not_to include('notion_sync')
    end
  end

  describe 'session_trace' do
    before do
      config = Struct.new(:session_store, :embedding_model, :embedding_provider,
                          :vector_store, :session_tracer_enabled, :enable_snapshots,
                          :notion_api_token, :console_mcp_enabled, :context_format).new(
                            nil, nil, nil, nil, false, false, nil, false, :markdown
                          )
      Woods.configuration = config
    end

    after { Woods.configuration = nil }

    it 'is not registered when session_store is missing' do
      srv = Woods::MCP::Server.build(index_dir: fixture_dir)
      tools = srv.instance_variable_get(:@tools)
      expect(tools.keys).not_to include('session_trace')
    end
  end
end
