# frozen_string_literal: true

require 'spec_helper'
require 'woods/mcp/bearer_auth'

RSpec.describe Woods::MCP::BearerAuth do
  let(:inner_app) { ->(_env) { [200, { 'content-type' => 'text/plain' }, ['ok']] } }
  let(:token) { 'sekret-token-abc123' }
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
    status, = call('Bearer wrong-token-abc123')
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
end
