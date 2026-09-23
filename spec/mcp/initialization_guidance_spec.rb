# frozen_string_literal: true

require 'spec_helper'
require 'woods'
require 'woods/mcp/server'

RSpec.describe 'Index MCP initialization guidance' do
  let(:fixture_dir) { File.expand_path('../fixtures/woods', __dir__) }

  before { Woods.configuration = Woods::Configuration.new }

  def build(**options)
    Woods::MCP::Server.build(index_dir: fixture_dir, warmup: false, **options)
  end

  def initialize_result(server, version: '2025-06-18')
    request = { jsonrpc: '2.0', id: 1, method: 'initialize',
                params: { protocolVersion: version, capabilities: {},
                          clientInfo: { name: 'guidance-spec', version: '1' } } }
    JSON.parse(server.handle_json(JSON.generate(request))).fetch('result')
  end

  def registered_names(instructions)
    instructions.lines.last.delete_prefix('Registered tools: ').strip.split(', ')
  end

  it 'gives a concise status, discovery, traversal and verification workflow' do
    text = initialize_result(build).fetch('instructions')

    expect(text).to start_with('Start with woods_status')
    expect(text).to include('search', 'lookup', 'depth 1 or 2', 'types and via',
                            'partial', 'current source', 'not proof of absence')
    expect(text.bytesize).to be <= 2048
  end

  it 'requires current retrieval status even when a retriever is wired' do
    retriever = double('retriever')
    expect(retriever).not_to receive(:retrieve)
    lean = initialize_result(build).fetch('instructions')
    wired = initialize_result(build(retriever: retriever)).fetch('instructions')

    expect(wired).to eq(lean)
    expect(wired).to include('check retrieval mode and data in woods_status before codebase_retrieve')
    expect(wired).to include('Otherwise use search and lookup')
  end

  it 'does not promise retrieval when bootstrap is degraded' do
    state = Woods::MCP::BootstrapState.new
    state.mark(:degraded, reason: RuntimeError.new('provider unavailable'))

    text = initialize_result(build(bootstrap_state: state)).fetch('instructions')

    expect(text).to include('structural readiness alone is insufficient')
    expect(text).not_to include('provider unavailable')
  end

  it 'does not grant Console or maintenance authorization' do
    expect(initialize_result(build).fetch('instructions'))
      .to include('Registration does not authorize extraction, configuration changes, or live Console access')
  end

  it 'lists only registered tools, including every combination of specialized wiring' do
    [false, true].repeated_permutation(5) do |operator, feedback, snapshots, sessions, notion|
      config = Woods::Configuration.new
      config.session_store = double('sessions', read: nil, sessions: []) if sessions
      config.notion_api_token = notion ? 'fixture-token' : nil
      config.notion_database_ids = notion ? { models: 'fixture-database' } : {}
      Woods.configuration = config
      server = build(operator: ({} if operator), feedback_store: (double('feedback') if feedback),
                     snapshot_store: (double('snapshots') if snapshots))
      text = initialize_result(server).fetch('instructions')

      expect(registered_names(text)).to eq(server.tools.keys.sort)
      expect(text.bytesize).to be <= 2048
      expect(server.tools.size).to eq(29) if operator && feedback && snapshots && sessions && notion
    end
  end

  it 'is stable across builds and index configuration that does not change tool wiring' do
    original = initialize_result(build).fetch('instructions')
    Woods.configuration.context_format = :plain

    expect(initialize_result(build).fetch('instructions')).to eq(original)
  end

  %w[2025-03-26 2025-06-18 2025-11-25].each do |version|
    it "includes guidance when negotiating #{version}" do
      result = initialize_result(build, version: version)

      expect(result['protocolVersion']).to eq(version)
      expect(result['instructions']).to start_with('Start with woods_status')
    end
  end

  it 'preserves the SDK omission for protocol 2024-11-05' do
    result = initialize_result(build, version: '2024-11-05')

    expect(result['protocolVersion']).to eq('2024-11-05')
    expect(result).not_to have_key('instructions')
  end

  it 'also supplies guidance through modern discovery without an initialization handshake' do
    server = build
    request = { jsonrpc: '2.0', id: 1, method: 'server/discover', params: {} }
    result = JSON.parse(server.handle_json(JSON.generate(request))).fetch('result')

    expect(result['instructions']).to eq(initialize_result(server).fetch('instructions'))
    expect(result['cacheScope']).to eq('private')
  end

  it 'does not change another MCP server' do
    build

    expect(MCP::Server.new(name: 'foreign', version: '1').instructions).to be_nil
  end

  it 'answers initialize without probing providers, extracting or writing configuration' do
    retriever = double('retriever')
    server = build(retriever: retriever)
    expect(retriever).not_to receive(:retrieve)
    expect(Woods).not_to receive(:extract!)
    expect(File).not_to receive(:write)
    expect(Woods::MCP::IndexReader).not_to receive(:new)

    expect(initialize_result(server).fetch('instructions')).to start_with('Start with woods_status')
  end
end
