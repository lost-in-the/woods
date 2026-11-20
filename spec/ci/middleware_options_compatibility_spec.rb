# frozen_string_literal: true

require 'spec_helper'
require 'woods'
require 'woods/mcp/bearer_auth'
require 'woods/mcp/origin_guard'

RSpec.describe 'Rails positional middleware options' do
  let(:app) { ->(_env) { [200, {}, ['next app']] } }
  let(:token) { 'a' * 64 }

  it 'accepts legacy bearer options without weakening authentication' do
    middleware = Woods::MCP::BearerAuth.new(app, { token: token })
    expect(middleware.call({}).first).to eq(401)
    expect(middleware.call('HTTP_AUTHORIZATION' => "Bearer #{token}").first).to eq(200)
  end

  it 'gives explicit bearer keywords precedence, including nil path and enabled predicate' do
    middleware = Woods::MCP::BearerAuth.new(
      app, { token: 'b' * 64, path: '/old', enabled: -> { false } },
      token: token, path: nil, enabled: nil
    )
    expect(middleware.call('PATH_INFO' => '/new').first).to eq(401)
    expect(middleware.call('HTTP_AUTHORIZATION' => "Bearer #{token}").first).to eq(200)
    expect(middleware.call('HTTP_AUTHORIZATION' => "Bearer #{'b' * 64}").first).to eq(401)
  end

  it 'preserves required token and explicit nil token refusal' do
    expect { Woods::MCP::BearerAuth.new(app, {}) }.to raise_error(ArgumentError, /token/)
    expect { Woods::MCP::BearerAuth.new(app, { token: token }, token: nil) }.to raise_error(ArgumentError)
  end

  it 'gives explicit nil origin keywords precedence over permissive legacy options' do
    middleware = Woods::MCP::OriginGuard.new(
      app, { allowed_origins: ['https://example.com'], path: '/old', enabled: -> { false } },
      allowed_origins: nil, path: nil, enabled: nil
    )
    expect(middleware.call('HTTP_ORIGIN' => 'https://example.com', 'PATH_INFO' => '/new').first).to eq(403)
    expect(middleware.call('HTTP_ORIGIN' => 'http://localhost', 'HTTP_HOST' => 'localhost').first).to eq(200)
  end

  [Woods::MCP::BearerAuth, Woods::MCP::OriginGuard].each do |middleware_class|
    it "rejects unknown positional and explicit options for #{middleware_class}" do
      required = middleware_class == Woods::MCP::BearerAuth ? { token: token } : {}
      expect { middleware_class.new(app, required.merge(typo: true)) }.to raise_error(ArgumentError, /unknown keyword/)
      expect { middleware_class.new(app, required, typo: true) }.to raise_error(ArgumentError, /unknown keyword/)
    end

    it "rejects non-Hash positional options for #{middleware_class}" do
      expect { middleware_class.new(app, nil) }.to raise_error(TypeError, /Hash/)
    end
  end
end
