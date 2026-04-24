# frozen_string_literal: true

require 'spec_helper'
require 'woods/mcp/origin_guard'

RSpec.describe Woods::MCP::OriginGuard do
  let(:inner_app) { ->(_env) { [200, { 'content-type' => 'text/plain' }, ['ok']] } }

  def call(middleware, origin: nil, method: 'POST')
    env = { 'REQUEST_METHOD' => method }
    env['HTTP_ORIGIN'] = origin if origin
    middleware.call(env)
  end

  describe 'default (loopback-only) policy' do
    subject(:middleware) { described_class.new(inner_app) }

    it 'allows requests with no Origin header (curl, server-to-server)' do
      status, = call(middleware, origin: nil)
      expect(status).to eq(200)
    end

    it 'allows http://localhost' do
      expect(call(middleware, origin: 'http://localhost').first).to eq(200)
    end

    it 'allows http://localhost:5173 (matches host regardless of port)' do
      expect(call(middleware, origin: 'http://localhost:5173').first).to eq(200)
    end

    it 'allows http://127.0.0.1' do
      expect(call(middleware, origin: 'http://127.0.0.1').first).to eq(200)
    end

    it 'rejects http://evil.example.com' do
      status, _headers, body = call(middleware, origin: 'http://evil.example.com')
      expect(status).to eq(403)
      parsed = JSON.parse(body.first)
      expect(parsed['error']['message']).to match(/Origin not allowed/)
    end

    it 'does not echo the rejected origin value in the response body' do
      malicious = 'http://evil.example.com/<script>alert(1)</script>'
      _status, _headers, body = call(middleware, origin: malicious)
      expect(body.first).not_to include('evil.example.com')
      expect(body.first).not_to include('<script>')
    end

    it 'adds CORS headers to allowed responses' do
      _status, headers, = call(middleware, origin: 'http://localhost')
      expect(headers['access-control-allow-origin']).to eq('http://localhost')
      expect(headers['vary']).to eq('Origin')
    end

    it 'answers OPTIONS preflight with 204 for allowed origins' do
      status, headers, = call(middleware, origin: 'http://localhost', method: 'OPTIONS')
      expect(status).to eq(204)
      expect(headers['access-control-allow-methods']).to include('POST')
    end
  end

  describe 'explicit allow-list' do
    subject(:middleware) { described_class.new(inner_app, allowed_origins: ['https://app.example.com']) }

    it 'allows configured origin' do
      expect(call(middleware, origin: 'https://app.example.com').first).to eq(200)
    end

    it 'rejects loopback when a custom allow-list is set' do
      expect(call(middleware, origin: 'http://localhost').first).to eq(403)
    end

    it 'rejects other origins' do
      expect(call(middleware, origin: 'https://other.example.com').first).to eq(403)
    end

    it 'is case-insensitive' do
      expect(call(middleware, origin: 'https://APP.example.com').first).to eq(200)
    end
  end
end
