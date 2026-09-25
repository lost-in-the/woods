# frozen_string_literal: true

require 'spec_helper'
require 'mcp'
require 'rack/mock'
require 'woods/mcp/origin_guard'

RSpec.describe 'HTTP origin policy with the real MCP transport' do
  after do
    # Stateful SDK transports own session-reaper threads. Close this example's
    # transports so later specs do not wait on their unrelated background work.
    Array(@transports).each { |transport| transport.close if transport.respond_to?(:close) }
  end

  def request(app, method:, origin: nil, host: 'localhost:9292', rpc_method: 'initialize', session: nil)
    params = if rpc_method == 'initialize'
               { protocolVersion: '2025-06-18', capabilities: {},
                 clientInfo: { name: 'origin-policy-spec', version: '1' } }
             else
               {}
             end
    body = JSON.generate(jsonrpc: '2.0', id: 1, method: rpc_method, params: params)
    env = Rack::MockRequest.env_for('/mcp', method: method, input: body,
                                            'CONTENT_TYPE' => 'application/json',
                                            'HTTP_ACCEPT' => 'application/json, text/event-stream')
    env['HTTP_ORIGIN'] = origin unless origin.nil?
    env['HTTP_HOST'] = host unless host.nil?
    env['HTTP_MCP_SESSION_ID'] = session if session
    env['HTTP_MCP_PROTOCOL_VERSION'] = '2025-06-18'
    app.call(env)
  end

  def build_app(origins, stateless: true)
    policy = Woods::MCP::OriginPolicy.new(allowed_origins: origins)
    server = MCP::Server.new(name: 'origin-policy', version: '1')
    transport = MCP::Server::Transports::StreamableHTTPTransport.new(
      server, stateless: stateless, **policy.transport_options
    )
    (@transports ||= []) << transport
    server.transport = transport
    guarded = Woods::MCP::OriginGuard.new(
      ->(env) { transport.handle_request(Rack::Request.new(env)) }, policy: policy
    )
    [guarded, transport]
  end

  [true, false].each do |stateless|
    context "with stateless=#{stateless}" do
      cases = [
        [[], 'http://localhost:9292', 'localhost:9292', 200],
        [[], 'https://localhost:9292', 'localhost:9292', 200],
        [[], 'http://localhost:5173', 'localhost:9292', 403],
        [[], 'http://localhost', 'localhost:80', 200],
        [[], 'http://localhost:80', 'localhost', 200],
        [[], 'https://localhost:443', 'localhost', 200],
        [[], 'http://[::1]:9292', '[::1]:9292', 200],
        [[], nil, '[::1]:9292', 200],
        [[], nil, nil, 200],
        [[], 'http://localhost', nil, 403],
        [[], '', 'localhost:9292', 403],
        [[], 'null', 'localhost:9292', 403],
        [[], nil, '', 403],
        [[], nil, 'localhost.:9292', 403],
        [[], nil, 'unlisted.example', 403],
        [['https://app.example'], 'https://app.example', 'localhost:9292', 200],
        [['https://app.example'], 'https://app.example:4443', 'app.example:4443', 200],
        [['https://app.example'], 'https://app.example:4443', 'localhost:9292', 403],
        [['https://app.example'], 'http://app.example:4443', 'app.example:4443', 403],
        [['https://app.example'], 'http://localhost:9292', 'localhost:9292', 403],
        [['https://app.example:4443'], 'https://app.example:5555', 'app.example:5555', 403],
        [['https://app.example:4443'], 'https://app.example:4443', 'app.example:4443', 200],
        [['https://app.example:4443'], nil, 'app.example:5555', 403],
        [['https://app.example:443'], nil, 'app.example:443', 200],
        [['https://app.example:443'], nil, 'app.example', 200],
        [['https://app.example:443'], 'https://app.example', 'localhost:9292', 200],
        [['https://app.example'], 'https://app.example:443', 'localhost:9292', 200],
        [['http://app.example:80'], 'http://app.example', 'localhost:9292', 200],
        [['https://[2001:db8::1]'], 'https://[2001:db8::1]:4443', '[2001:db8::1]:4443', 200],
        [['https://[2001:db8::1]:4443'], 'https://[2001:db8::1]:4443', 'localhost:9292', 200],
        [['https://APP.example/'], 'https://app.EXAMPLE', 'APP.example', 200],
        [['https://app.example.'], 'https://app.example.', 'app.example.', 200],
        [['https://app.example'], 'https://app.example/', 'app.example', 403]
      ]

      cases.each_with_index do |(origins, origin, host, expected), index|
        it "agrees between preflight and SDK dispatch for case #{index + 1}" do
          app, = build_app(origins, stateless: stateless)
          preflight = request(app, method: 'OPTIONS', origin: origin, host: host)
          response = request(app, method: 'POST', origin: origin, host: host)

          expect(preflight.first).to eq(expected == 200 ? 204 : expected)
          expect(response.first).to eq(expected)
          if expected == 200
            expect(JSON.parse(response.last.first).dig('result', 'serverInfo', 'name')).to eq('origin-policy')
          end
        end
      end
    end
  end

  it 'retains independent SDK rebinding validation' do
    _, transport = build_app(['https://app.example'])
    sdk = ->(env) { transport.handle_request(Rack::Request.new(env)) }

    expect(request(sdk, method: 'POST', origin: 'https://foreign.example').first).to eq(403)
    expect(request(sdk, method: 'POST', host: 'foreign.example').first).to eq(403)
  end

  it 'keeps session Origin binding after a permitted initialization' do
    app, = build_app(%w[https://app.example https://other.example], stateless: false)
    initialized = request(app, method: 'POST', origin: 'https://app.example')
    session = initialized[1].transform_keys(&:downcase).fetch('mcp-session-id')

    same = request(app, method: 'POST', rpc_method: 'tools/list', session: session,
                        origin: 'https://app.example')
    changed = request(app, method: 'POST', rpc_method: 'tools/list', session: session,
                           origin: 'https://other.example')
    expect(same.first).to eq(200)
    expect(changed.first).to eq(403)
  end

  it 'captures one immutable policy for concurrent first requests' do
    resolutions = Queue.new
    origins = ['https://app.example']
    app = Woods::MCP::OriginGuard.new(->(_env) { [200, {}, ['ok']] }, allowed_origins: lambda {
      resolutions << true
      origins
    })
    policies = Array.new(8) { Thread.new { app.policy } }.map(&:value)
    origins << 'https://later.example'

    expect(resolutions.size).to eq(1)
    expect(policies.map(&:object_id).uniq.size).to eq(1)
    expect(policies.first).to be_frozen
    expect(policies.first.transport_options.fetch(:allowed_origins))
      .to eq(['https://app.example', 'https://app.example:443'])
    expect(policies.first.transport_options.fetch(:allowed_origins)).to be_frozen
  end
end
