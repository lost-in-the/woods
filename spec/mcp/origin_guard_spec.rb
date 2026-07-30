# frozen_string_literal: true

require 'spec_helper'
require 'woods/mcp/origin_guard'

RSpec.describe Woods::MCP::OriginGuard do
  let(:inner_app) { ->(_env) { [200, { 'content-type' => 'text/plain' }, ['ok']] } }

  def call(middleware, origin: nil, method: 'POST', host: nil, path: nil)
    env = { 'REQUEST_METHOD' => method }
    env['HTTP_ORIGIN'] = origin if origin
    env['HTTP_HOST'] = host if host
    env['PATH_INFO'] = path if path
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

    it 'returns a spec-compliant JSON-RPC error envelope on rejection' do
      _status, headers, body = call(middleware, origin: 'http://evil.example.com')
      expect(headers['content-type']).to eq('application/json')
      parsed = JSON.parse(body.first)
      expect(parsed).to include('jsonrpc' => '2.0', 'id' => nil)
      expect(parsed['error']).to include('code' => -32_002, 'message' => 'Origin not allowed')
    end

    it 'rejects origins with CRLF / control characters without reflecting them' do
      malicious = "http://localhost\r\nX-Injected: yes"
      status, headers, body = call(middleware, origin: malicious)
      expect(status).to eq(403)
      expect(headers).not_to have_key('X-Injected')
      expect(body.first).not_to include("\r\n")
      expect(body.first).not_to include('X-Injected')
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
      expect(parsed['error']['message']).to eq('Host not allowed')
      # Rejection body must NOT echo the attacker-controlled header value.
      expect(body.first).not_to include('attacker.example.com')
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

    it 'rejects a hex-notation IPv4 Host (0x7f000001 = 127.0.0.1)' do
      status, = call(middleware, host: '0x7f000001:3000')
      expect(status).to eq(403)
    end

    it 'rejects a bare-integer IPv4 Host (2130706433 = 127.0.0.1)' do
      status, = call(middleware, host: '2130706433:3000')
      expect(status).to eq(403)
    end

    it 'rejects a leading-zero octal Host (0177.0.0.1 = 127.0.0.1)' do
      status, = call(middleware, host: '0177.0.0.1:3000')
      expect(status).to eq(403)
    end

    it 'rejects short-form IPv4 (127.1 = 127.0.0.1)' do
      status, = call(middleware, host: '127.1:3000')
      expect(status).to eq(403)
    end

    it 'rejects mixed-radix IPv4 (0x7f.0.0.1 = 127.0.0.1)' do
      status, = call(middleware, host: '0x7f.0.0.1:3000')
      expect(status).to eq(403)
    end
  end

  # Regression for #183: the railtie used to mount OriginGuard with no path
  # scoping, so any non-loopback Host 403'd the ENTIRE host app. With
  # `path:` set, only requests under that prefix are guarded.
  describe 'path scoping (path: kwarg)' do
    subject(:middleware) { described_class.new(inner_app, path: '/mcp/console') }

    it 'passes GET / with a disallowed Origin through untouched' do
      status, headers, body = call(middleware, origin: 'http://evil.example.com', path: '/')
      expect(status).to eq(200)
      expect(body).to eq(['ok'])
      expect(headers).not_to have_key('access-control-allow-origin')
    end

    it 'passes a non-loopback Host through untouched outside the scoped path' do
      status, = call(middleware, host: 'app.internal.example.com', path: '/posts')
      expect(status).to eq(200)
    end

    it 'still rejects a disallowed Origin at the scoped path' do
      status, = call(middleware, origin: 'http://evil.example.com', path: '/mcp/console')
      expect(status).to eq(403)
    end

    it 'still rejects a disallowed Host on subpaths of the scoped path' do
      status, = call(middleware, host: 'attacker.example.com', path: '/mcp/console/rpc')
      expect(status).to eq(403)
    end

    it 'still allows loopback requests at the scoped path' do
      status, = call(middleware, origin: 'http://localhost', host: 'localhost:3000', path: '/mcp/console')
      expect(status).to eq(200)
    end
  end

  describe 'with path: nil (default)' do
    subject(:middleware) { described_class.new(inner_app) }

    it 'guards every path — existing standalone behavior' do
      status, = call(middleware, origin: 'http://evil.example.com', path: '/')
      expect(status).to eq(403)
    end
  end

  # Request-time enablement — the railtie passes a proc reading
  # Woods.configuration.console_mcp_enabled so a flag set in
  # config/initializers takes effect (#183).
  describe 'enabled predicate (enabled: kwarg)' do
    it 'passes requests through unguarded while the predicate returns false' do
      middleware = described_class.new(inner_app, enabled: -> { false })
      status, = call(middleware, origin: 'http://evil.example.com')
      expect(status).to eq(200)
    end

    it 'evaluates the predicate on every request' do
      on = false
      middleware = described_class.new(inner_app, enabled: -> { on })

      expect(call(middleware, origin: 'http://evil.example.com').first).to eq(200)
      on = true
      expect(call(middleware, origin: 'http://evil.example.com').first).to eq(403)
    end
  end

  # Regression for #183: middleware arguments are captured before
  # config/initializers run, so an allow-list configured there must be
  # resolved lazily, not at construction time.
  describe 'deferred (callable) allow-list' do
    it 'resolves the allow-list at request time, not construction time' do
      origins = []
      middleware = described_class.new(inner_app, allowed_origins: -> { origins })
      origins << 'https://app.example.com' # set after construction

      expect(call(middleware, origin: 'https://app.example.com').first).to eq(200)
      expect(call(middleware, origin: 'http://localhost').first).to eq(403)
    end

    it 'falls back to the loopback defaults when the callable returns an empty list' do
      middleware = described_class.new(inner_app, allowed_origins: -> { [] })

      expect(call(middleware, origin: 'http://localhost').first).to eq(200)
      expect(call(middleware, origin: 'http://evil.example.com').first).to eq(403)
    end
  end
end
