# frozen_string_literal: true

require 'spec_helper'
require 'json'
require 'tmpdir'
require 'fileutils'
require 'rack/mock'

# Separate Rails process, like the credential-rotation fixture: use the actual
# Console middleware/server/SDK with the same outer guards as the Railtie.
RSpec.describe 'Console HTTP allowlist integration', :booted_app do
  before(:all) do
    require 'logger'
    require 'rails'
    require 'active_record'
    require 'woods'
    require 'woods/console/rack_middleware'
    require 'woods/mcp/origin_guard'
    require 'woods/mcp/bearer_auth'

    @root = Dir.mktmpdir('woods-console-http')
    app = Class.new(Rails::Application)
    app.config.root = @root
    app.config.eager_load = false
    app.config.logger = Logger.new(File::NULL)
    app.config.secret_key_base = 'synthetic-console-http-fixture'
    app.initialize!
    @original_config = Woods.configuration
    ActiveRecord::Base.establish_connection(adapter: 'sqlite3', database: ':memory:')
  end

  after(:all) do
    ActiveRecord::Base.remove_connection
    Woods.configuration = @original_config
    FileUtils.remove_entry(@root)
  end

  def dispatch(origins, host: 'console.example.invalid', origin: 'https://console.example.invalid', authenticated: true, # rubocop:disable Metrics/MethodLength -- exercises both real guarded Rack stacks
               manual_mount: false)
    Woods.configuration = Woods::Configuration.new
    Woods.configuration.console_mcp_enabled = true
    Woods.configuration.console_mcp_allowed_origins = origins
    middleware = Woods::Console::RackMiddleware.new(->(_env) { [404, {}, []] })
    token = 'synthetic-console-http-fixture-long-token'
    Woods.configuration.console_mcp_token = token
    app = Woods::MCP::OriginGuard.new(Woods::MCP::BearerAuth.new(middleware, token: token), allowed_origins: origins)
    app = Woods::Console::RackMiddleware.new(app) if manual_mount
    payload = JSON.generate(jsonrpc: '2.0', id: 1, method: 'initialize', params: {
                              protocolVersion: '2025-03-26', capabilities: {},
                              clientInfo: { name: 'console-http-fixture', version: '1' }
                            })
    env = Rack::MockRequest.env_for(
      "https://#{host}/mcp/console", method: 'POST', input: payload,
                                     'CONTENT_TYPE' => 'application/json', 'HTTP_HOST' => host,
                                     'HTTP_ACCEPT' => 'application/json, text/event-stream'
    )
    env['HTTP_ORIGIN'] = origin
    env['HTTP_AUTHORIZATION'] = "Bearer #{token}" if authenticated
    status, _, body = app.call(env)
    body.close if body.respond_to?(:close)
    status
  end

  it 'forwards explicitly configured remote origins and hosts to the real SDK' do
    expect(dispatch(['https://console.example.invalid'])).to eq(200)
  end

  it 'retains loopback defaults and refuses unconfigured remote hosts' do
    origins = Woods::Configuration.new.console_mcp_allowed_origins
    expect(dispatch(origins, host: 'localhost', origin: 'http://localhost')).to eq(200)
    expect(dispatch(origins)).to eq(403)
  end

  it 'preserves bearer authentication and rejects foreign origins' do
    origins = ['https://console.example.invalid']
    expect(dispatch(origins, authenticated: false)).to eq(401)
    expect(dispatch(origins, origin: 'https://foreign.example.invalid')).to eq(403)
  end

  it 'requires explicit ports for cross-origin browser requests' do
    args = { host: 'localhost:9292', origin: 'http://localhost:3000' }
    expect(dispatch(['http://localhost'], **args)).to eq(403)
    expect(dispatch(['http://localhost:3000'], **args)).to eq(200)
  end

  it 'guards a manual mount preceding the outer guards using the real SDK' do
    origins = ['https://console.example.invalid']
    expect(dispatch(origins, manual_mount: true)).to eq(200)
    expect(dispatch(origins, manual_mount: true, authenticated: false)).to eq(401)
    expect(dispatch(origins, manual_mount: true, origin: 'https://foreign.invalid')).to eq(403)
    expect(dispatch(origins, manual_mount: true, host: 'foreign.invalid')).to eq(403)
  end
end
