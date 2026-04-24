# frozen_string_literal: true

require 'spec_helper'
require 'woods/mcp/origin_guard'

RSpec.describe Woods::MCP::OriginGuard do
  let(:inner_app) { ->(_env) { [200, { 'content-type' => 'text/plain' }, ['ok']] } }

  def call(middleware, origin: nil, method: 'POST', host: nil)
    env = { 'REQUEST_METHOD' => method }
    env['HTTP_ORIGIN'] = origin if origin
    env['HTTP_HOST'] = host if host
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

  describe 'Host header validation (DNS-rebinding defense)' do
    subject(:middleware) { described_class.new(inner_app) }

    it 'allows loopback hosts even when the server is bound to 0.0.0.0' do
      expect(call(middleware, host: 'localhost:3000').first).to eq(200)
      expect(call(middleware, host: '127.0.0.1:9292').first).to eq(200)
      expect(call(middleware, host: '[::1]:8080').first).to eq(200)
    end

    it 'rejects an attacker-controlled Host header pointed at the same IP' do
      status, _headers, body = call(middleware, host: 'attacker.example.com')
      expect(status).to eq(403)
      parsed = JSON.parse(body.first)
      expect(parsed['error']['message']).to match(/Host not allowed/)
    end

    it 'allows configured non-loopback hosts' do
      guarded = described_class.new(inner_app, allowed_origins: ['https://app.example.com'])
      expect(call(guarded, host: 'app.example.com').first).to eq(200)
    end

    it 'still rejects an unknown Host even when Origin is absent' do
      status, = call(middleware, host: 'attacker.example.com', origin: nil)
      expect(status).to eq(403)
    end

    it 'treats the FQDN trailing-dot form of loopback as loopback' do
      expect(call(middleware, host: 'localhost.:3000').first).to eq(200)
    end
  end
end
