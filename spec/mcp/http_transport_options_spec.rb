# frozen_string_literal: true

require 'spec_helper'
require 'woods'
require 'rack/mock'
require 'woods/mcp/server'
require 'woods/mcp/origin_guard'
require 'woods/mcp/bearer_auth'
require 'woods/mcp/http_transport_options'

RSpec.describe Woods::MCP::HttpTransportOptions do
  let(:token) { 'synthetic-http-fixture-token-long-enough' }

  after do
    Array(@transports).each { |transport| transport.close if transport.respond_to?(:close) }
  end

  def dispatch(origins:, host: 'mcp.example.invalid', origin: 'https://mcp.example.invalid', bearer: token) # rubocop:disable Metrics/AbcSize -- dispatches through both guards and the real SDK
    server = Woods::MCP::Server.build(index_dir: File.expand_path('../fixtures/woods', __dir__), warmup: false)
    transport = MCP::Server::Transports::StreamableHTTPTransport.new(server, **described_class.for(origins))
    (@transports ||= []) << transport
    server.transport = transport
    inner = ->(env) { transport.handle_request(Rack::Request.new(env)) }
    app = Woods::MCP::OriginGuard.new(Woods::MCP::BearerAuth.new(inner, token: token), allowed_origins: origins)
    payload = JSON.generate(jsonrpc: '2.0', id: 1, method: 'initialize', params: {
                              protocolVersion: '2025-03-26', capabilities: {},
                              clientInfo: { name: 'http-fixture', version: '1' }
                            })
    env = Rack::MockRequest.env_for(
      "https://#{host}/mcp", method: 'POST', input: payload,
                             'CONTENT_TYPE' => 'application/json', 'HTTP_HOST' => host,
                             'HTTP_ACCEPT' => 'application/json, text/event-stream'
    )
    env['HTTP_ORIGIN'] = origin if origin
    env['HTTP_AUTHORIZATION'] = "Bearer #{bearer}" if bearer
    status, _, body = app.call(env)
    body.close if body.respond_to?(:close)
    status
  end

  it 'retains SDK loopback defaults without configuration' do
    expect(described_class.for([])).to eq({})
    expect(dispatch(origins: [], host: 'localhost', origin: 'https://localhost')).to eq(200)
    expect(dispatch(origins: [])).to eq(403)
  end

  it 'normalizes valid URLs while preserving explicit authority ports' do
    expect(described_class.for([' HTTPS://MCP.EXAMPLE.INVALID:8443/ '])).to eq(
      allowed_origins: ['https://mcp.example.invalid:8443'],
      allowed_hosts: ['mcp.example.invalid:8443']
    )
  end

  %w[invalid-entry https://example.test/path * null file:///tmp/x].each do |entry|
    it 'refuses malformed configured entries before constructing the transport' do
      expect { described_class.for([entry]) }.to raise_error(ArgumentError, /Invalid MCP allowed origin/)
    end
  end

  it 'bounds and escapes undecodable configuration diagnostics' do
    entry = ("invalid-\xFF\n" * 30).force_encoding(Encoding::UTF_8)
    expect { described_class.for([entry]) }.to raise_error(ArgumentError) do |error|
      expect(error.message).to include('Invalid MCP allowed origin', '\\xFF', '\\n')
      expect(error.message.lines.length).to eq(1)
      expect(error.message.bytesize).to be < 450
    end
  end

  it 'accepts equivalent default-port origins through both the guard and the legacy SDK' do
    expect(dispatch(origins: ['https://mcp.example.invalid:443'], host: 'localhost:9292')).to eq(200)
    expect(dispatch(origins: ['https://mcp.example.invalid'], host: 'localhost:9292',
                    origin: 'https://mcp.example.invalid:443')).to eq(200)
  end

  it 'accepts the configured remote origin through both guards, including non-browser clients' do
    expect(dispatch(origins: ['https://mcp.example.invalid'])).to eq(200)
    expect(dispatch(origins: ['https://mcp.example.invalid'], origin: nil)).to eq(200)
  end

  it 'preserves authentication and rejects foreign hosts and origins' do
    origins = ['https://mcp.example.invalid']
    expect(dispatch(origins: origins, bearer: nil)).to eq(401)
    expect(dispatch(origins: origins, bearer: 'wrong')).to eq(401)
    expect(dispatch(origins: origins, host: 'foreign.example.invalid')).to eq(403)
    expect(dispatch(origins: origins, origin: 'https://foreign.example.invalid')).to eq(403)
  end

  it 'requires the actual port for a different browser origin' do
    args = { host: 'localhost:9292', origin: 'http://localhost:3000' }
    expect(dispatch(origins: ['http://localhost'], **args)).to eq(403)
    expect(dispatch(origins: ['http://localhost:3000'], **args)).to eq(200)
  end
end
