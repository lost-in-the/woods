# frozen_string_literal: true

require 'spec_helper'
require 'woods/mcp/bearer_auth'

RSpec.describe Woods::MCP::BearerAuth do
  let(:inner_app) { ->(_env) { [200, { 'content-type' => 'text/plain' }, ['ok']] } }
  # 64 hex chars — satisfies the 32-char minimum. Using a literal so
  # failures are reproducible across runs; real deployments should
  # generate tokens via SecureRandom.hex(32).
  let(:token) { '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef' }
  let(:middleware) { described_class.new(inner_app, token: token) }

  def call(auth_header)
    env = {}
    env['HTTP_AUTHORIZATION'] = auth_header if auth_header
    middleware.call(env)
  end

  it 'forwards the request when the bearer token matches' do
    status, _headers, body = call("Bearer #{token}")
    expect(status).to eq(200)
    expect(body).to eq(['ok'])
  end

  it 'accepts ASCII case variants of the scheme while preserving exact token bytes' do
    %w[bearer BEARER BeArEr].each { |scheme| expect(call("#{scheme} #{token}").first).to eq(200) }
    expect(call("Bearer #{token.upcase}").first).to eq(401)
    expect(call("Bearer  #{token}").first).to eq(401)
    expect(call("Bearer #{token} ").first).to eq(401)
    expect(call("Bearer \xFF").first).to eq(401)
  end

  it 'supports token rotation and scopes deferred authentication to the Console path' do
    current = token
    app = described_class.new(inner_app, token: -> { current }, path: '/mcp/console')
    expect(app.call('PATH_INFO' => '/ordinary').first).to eq(200)
    request = { 'PATH_INFO' => '/mcp/console', 'HTTP_AUTHORIZATION' => "Bearer #{token}" }
    expect(app.call(request).first).to eq(200)
    current = 'replacement-fixture-token-' * 3
    expect(app.call(request).first).to eq(401)
    expect(app.call(request.merge('HTTP_AUTHORIZATION' => "Bearer #{current}")).first).to eq(200)
    [nil, '', 'short'].each do |invalid|
      current = invalid
      expect(app.call(request).first).to eq(401)
    end
  end

  it 'returns 401 when the Authorization header is missing' do
    status, headers, _body = call(nil)
    expect(status).to eq(401)
    expect(headers['www-authenticate']).to match(/Bearer/)
  end

  it 'returns 401 when the scheme is not Bearer' do
    status, = call("Basic #{token}")
    expect(status).to eq(401)
  end

  it 'returns 401 when the token is wrong' do
    status, = call("Bearer #{'w' * token.length}")
    expect(status).to eq(401)
  end

  it 'returns 401 when the presented token length differs' do
    status, = call('Bearer short')
    expect(status).to eq(401)
  end

  it 'returns a JSON-RPC-shaped error body' do
    _status, headers, body = call(nil)
    expect(headers['content-type']).to eq('application/json')
    parsed = JSON.parse(body.first)
    expect(parsed['error']['message']).to eq('Unauthorized')
  end

  it 'raises when constructed with nil token' do
    expect { described_class.new(inner_app, token: nil) }.to raise_error(ArgumentError)
  end

  it 'raises when constructed with empty token' do
    expect { described_class.new(inner_app, token: '') }.to raise_error(ArgumentError)
  end

  it 'raises when constructed with a token shorter than the minimum length' do
    expect { described_class.new(inner_app, token: 'too-short') }
      .to raise_error(ArgumentError, /at least 32 characters/)
  end
end
