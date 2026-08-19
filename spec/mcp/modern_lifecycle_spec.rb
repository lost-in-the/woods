# frozen_string_literal: true

require 'spec_helper'
require 'json'
require 'mcp'
require 'woods'
require 'woods/dependency_graph'
require 'woods/mcp/server'

# Coverage for the MCP 2026-07-28 "modern" lifecycle (SEP-2575): no `initialize`
# handshake, per-request metadata, and `server/discover`.
#
# These assert Woods' *observable protocol behaviour* through a real built
# server, not the SDK's internals — the point is that a client speaking either
# era gets served, which is the property the gem upgrade is for.
RSpec.describe 'MCP modern lifecycle' do
  let(:fixture_dir) { File.expand_path('../fixtures/woods', __dir__) }
  let(:server) { Woods::MCP::Server.build(index_dir: fixture_dir, response_format: :json, warmup: false) }

  # Modern requests carry version, identity and capabilities in `_meta` — there
  # is no prior handshake to have established them.
  def modern_meta(version: MCP::Configuration::LATEST_MODERN_PROTOCOL_VERSION, capabilities: {})
    {
      'io.modelcontextprotocol/protocolVersion' => version,
      'io.modelcontextprotocol/clientInfo' => { 'name' => 'spec-client', 'version' => '1.0' },
      'io.modelcontextprotocol/clientCapabilities' => capabilities
    }
  end

  def call(method, params = {}, id: 1)
    raw = server.handle_json(JSON.generate({ jsonrpc: '2.0', id: id, method: method, params: params }))
    raw && JSON.parse(raw)
  end

  describe 'the installed SDK' do
    it 'supports the 2026-07-28 protocol revision' do
      expect(MCP::Configuration::SUPPORTED_STABLE_PROTOCOL_VERSIONS).to include('2026-07-28')
    end

    # Dual-era is the entire compatibility story: a server that only spoke the
    # modern revision would fail every legacy client, and those have no
    # fall-forward mechanism.
    it 'still lists the legacy revisions it can serve' do
      expect(MCP::Configuration::SUPPORTED_STABLE_PROTOCOL_VERSIONS)
        .to include('2025-06-18', '2025-03-26', '2024-11-05')
    end
  end

  describe 'server/discover' do
    subject(:result) { call('server/discover', {})['result'] }

    it 'is answered without any prior initialize' do
      expect(result).to be_a(Hash)
    end

    it 'advertises the modern revision among its supported versions' do
      expect(result['supportedVersions']).to include('2026-07-28')
    end

    it 'identifies the server as woods' do
      expect(result.dig('_meta', 'io.modelcontextprotocol/serverInfo', 'name')).to eq('woods')
    end

    it 'reports the tools capability' do
      expect(result['capabilities']).to have_key('tools')
    end
  end

  describe 'requests without an initialize handshake' do
    it 'serves tools/list' do
      expect(call('tools/list', { '_meta' => modern_meta }).dig('result', 'tools')).not_to be_empty
    end

    it 'serves a tools/call' do
      result = call('tools/call', {
                      'name' => 'woods_status', 'arguments' => {}, '_meta' => modern_meta
                    })['result']
      expect(result['isError']).to be(false)
    end
  end

  describe 'the legacy era' do
    # The combination the compatibility matrix says must keep working: an older
    # client that opens with initialize against the same unmodified server.
    it 'still answers an initialize handshake' do
      result = call('initialize', {
                      'protocolVersion' => '2024-11-05',
                      'capabilities' => {},
                      'clientInfo' => { 'name' => 'legacy-client', 'version' => '1.0' }
                    })['result']
      expect(result['protocolVersion']).to be_a(String)
      expect(result.dig('serverInfo', 'name')).to eq('woods')
    end
  end

  describe 'cache hints on list results' do
    subject(:result) { call('tools/list', { '_meta' => modern_meta })['result'] }

    it 'carries a ttlMs freshness hint' do
      expect(result['ttlMs']).to eq(Woods::MCP::ProtocolPolicy.ttl_ms)
    end

    it 'restricts caching to the requesting client' do
      expect(result['cacheScope']).to eq('private')
    end
  end

  describe 'deterministic tool ordering' do
    it 'advertises tools in sorted order' do
      names = call('tools/list', { '_meta' => modern_meta }).dig('result', 'tools').map { |t| t['name'] }
      expect(names).to eq(names.sort)
    end

    # Wiring an optional integration must not reorder the tools a lean host
    # already had, or every agent turn on that host misses the prompt cache.
    it 'keeps the always-on tools in the same relative order when more tools are wired' do
      lean = call('tools/list', { '_meta' => modern_meta }).dig('result', 'tools').map { |t| t['name'] }

      wired = Woods::MCP::Server.build(
        index_dir: fixture_dir, response_format: :json, warmup: false,
        operator: { status_reporter: nil, pipeline_guard: nil, pipeline_lock: nil, error_escalator: nil }
      )
      raw = wired.handle_json(JSON.generate({ jsonrpc: '2.0', id: 2, method: 'tools/list',
                                              params: { '_meta' => modern_meta } }))
      rich = JSON.parse(raw).dig('result', 'tools').map { |t| t['name'] }

      expect(rich & lean).to eq(lean)
    end
  end
end
