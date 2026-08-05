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

  # Regression for #183: the railtie used to mount BearerAuth with no path
  # scoping, so enabling the console 401'd the ENTIRE host app (GET /
  # included). With `path:` set, only requests under that prefix are guarded.
  describe 'path scoping (path: kwarg)' do
    let(:seen_paths) { [] }
    let(:inner_app) do
      paths = seen_paths
      lambda do |env|
        paths << env['PATH_INFO']
        [200, { 'content-type' => 'text/plain' }, ['ok']]
      end
    end
    let(:middleware) { described_class.new(inner_app, token: token, path: '/mcp/console') }

    def request(path, auth_header: nil)
      env = { 'PATH_INFO' => path }
      env['HTTP_AUTHORIZATION'] = auth_header if auth_header
      middleware.call(env)
    end

    it 'passes GET / through untouched — app called, no 401' do
      status, _headers, body = request('/')
      expect(status).to eq(200)
      expect(body).to eq(['ok'])
      expect(seen_paths).to eq(['/'])
    end

    it 'passes unrelated paths through without consulting the Authorization header' do
      status, = request('/posts/1', auth_header: 'Bearer wrong')
      expect(status).to eq(200)
    end

    it 'still guards requests at the scoped path' do
      status, = request('/mcp/console')
      expect(status).to eq(401)
      expect(seen_paths).to be_empty
    end

    it 'guards subpaths of the scoped path' do
      status, = request('/mcp/console/anything')
      expect(status).to eq(401)
    end

    it 'forwards authorized requests at the scoped path' do
      status, _headers, body = request('/mcp/console', auth_header: "Bearer #{token}")
      expect(status).to eq(200)
      expect(body).to eq(['ok'])
    end
  end

  describe 'with path: nil (default)' do
    it 'guards every path — existing standalone behavior' do
      status, = middleware.call('PATH_INFO' => '/')
      expect(status).to eq(401)
    end
  end

  # Regression for #183: the railtie captures middleware arguments before
  # config/initializers run, so a token set there must be resolved at
  # request time, not construction time.
  describe 'deferred (callable) token' do
    it 'does not validate the token at construction time' do
      expect { described_class.new(inner_app, token: -> {}) }.not_to raise_error
    end

    it 'resolves the token at request time, not construction time' do
      current = nil
      middleware = described_class.new(inner_app, token: -> { current })
      current = token # set after construction — simulates config/initializers

      status, _headers, body = middleware.call('HTTP_AUTHORIZATION' => "Bearer #{token}")
      expect(status).to eq(200)
      expect(body).to eq(['ok'])
    end

    it 'reflects a token rotated between requests' do
      current = token
      middleware = described_class.new(inner_app, token: -> { current })
      rotated = 'f' * 40
      current = rotated

      expect(middleware.call('HTTP_AUTHORIZATION' => "Bearer #{token}").first).to eq(401)
      expect(middleware.call('HTTP_AUTHORIZATION' => "Bearer #{rotated}").first).to eq(200)
    end

    it 'fails closed with 401 while the callable returns nil' do
      middleware = described_class.new(inner_app, token: -> {})
      allow(middleware).to receive(:warn)

      status, = middleware.call('HTTP_AUTHORIZATION' => 'Bearer anything')
      expect(status).to eq(401)
    end

    it 'fails closed with 401 when the callable returns a too-short token' do
      middleware = described_class.new(inner_app, token: -> { 'short' })
      allow(middleware).to receive(:warn)

      status, = middleware.call('HTTP_AUTHORIZATION' => 'Bearer short')
      expect(status).to eq(401)
    end

    it 'warns once (not per request) about an unusable deferred token' do
      middleware = described_class.new(inner_app, token: -> {})
      allow(middleware).to receive(:warn)

      middleware.call({})
      middleware.call({})

      expect(middleware).to have_received(:warn)
        .with(a_string_including('no bearer token is configured')).once
    end
  end

  # Request-time enablement — the railtie passes a proc reading
  # Woods.configuration.console_mcp_enabled so a flag set in
  # config/initializers takes effect (#183).
  describe 'enabled predicate (enabled: kwarg)' do
    it 'passes requests through unguarded while the predicate returns false' do
      middleware = described_class.new(inner_app, token: token, enabled: -> { false })
      status, _headers, body = middleware.call({})
      expect(status).to eq(200)
      expect(body).to eq(['ok'])
    end

    it 'evaluates the predicate on every request' do
      on = false
      middleware = described_class.new(inner_app, token: token, enabled: -> { on })

      expect(middleware.call({}).first).to eq(200)
      on = true
      expect(middleware.call({}).first).to eq(401)
    end
  end
end
