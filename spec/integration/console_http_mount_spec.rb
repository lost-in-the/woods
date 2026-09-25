# frozen_string_literal: true

require 'spec_helper'
require 'json'
require 'open3'

RSpec.describe 'Legacy Console automatic HTTP mount', :booted_app do
  def boot(origins: 'https://console.example.invalid:443', token: 'synthetic-console-token-' * 3) # rubocop:disable Metrics/MethodLength -- isolated real Rails boot and HTTP requests
    root = File.expand_path('../..', __dir__)
    script = <<~'SCRIPT'
      require 'logger'
      require 'rails'
      require 'active_record'
      require 'action_controller/railtie'
      require 'tmpdir'
      require 'rack/mock'
      require 'woods'
      Woods.configure do |config|
        config.console_mcp_enabled = true
        config.console_mcp_path = '/private/console'
        config.console_mcp_token = ENV.fetch('FIXTURE_TOKEN')
        config.console_mcp_allowed_origins = ENV.fetch('FIXTURE_ORIGINS').split(',')
      end
      Dir.mktmpdir('woods-legacy-http') do |directory|
        app = Class.new(Rails::Application)
        app.config.root = directory
        app.config.eager_load = false
        app.config.logger = Logger.new(File::NULL)
        app.config.secret_key_base = 'synthetic-console-http-mount-fixture'
        app.config.hosts.clear if app.config.respond_to?(:hosts)
        app.initialize!
        Rails.application.routes.draw { get '/ordinary', to: ->(_env) { [204, {}, []] } }
        ActiveRecord::Base.establish_connection(adapter: 'sqlite3', database: ':memory:')
        payload = JSON.generate(jsonrpc: '2.0', id: 1, method: 'initialize', params: {
          protocolVersion: '2025-03-26', capabilities: {}, clientInfo: { name: 'legacy-http', version: '1' }
        })
        request = lambda do |token, origin = 'https://console.example.invalid', method = 'POST'|
          env = Rack::MockRequest.env_for('http://localhost/private/console', method: method, input: payload,
            'CONTENT_TYPE' => 'application/json', 'HTTP_ACCEPT' => 'application/json, text/event-stream',
            'HTTP_HOST' => 'localhost', 'HTTP_AUTHORIZATION' => "bearer #{token}", 'HTTP_ORIGIN' => origin)
          status, _, body = Rails.application.call(env)
          body.close if body.respond_to?(:close)
          status
        end
        old = Woods.configuration.console_mcp_token
        results = { ordinary: Rails.application.call(Rack::MockRequest.env_for('http://other.invalid/ordinary')).first,
          preflight: request.call(old, 'https://console.example.invalid', 'OPTIONS'),
          authorized: request.call(old), missing: request.call(''),
          excluded: request.call(old, 'http://localhost') }
        Woods.configuration.console_mcp_token = 'replacement-console-token-' * 3
        results[:old] = request.call(old)
        results[:rotated] = request.call(Woods.configuration.console_mcp_token)
        puts JSON.generate(results)
      end
    SCRIPT
    Open3.capture3({ 'FIXTURE_ORIGINS' => origins, 'FIXTURE_TOKEN' => token, 'RAILS_ENV' => 'test' },
                   RbConfig.ruby, '-Ilib', '-e', script, chdir: root)
  end

  it 'scopes authentication and origin checks while using current credentials with the real SDK' do
    out, err, status = boot
    expect(status).to be_success, err
    expect(JSON.parse(out)).to eq('ordinary' => 204, 'preflight' => 204, 'authorized' => 200,
                                  'missing' => 401, 'excluded' => 403, 'old' => 401, 'rotated' => 200)
  end

  it 'refuses malformed origin configuration during boot' do
    _out, err, status = boot(origins: 'invalid-entry')
    expect(status).not_to be_success
    expect(err).to include('Invalid MCP allowed origin')
  end

  it 'retains refusal of short startup credentials' do
    _out, err, status = boot(token: 'short')
    expect(status).not_to be_success
    expect(err).to include('must be at least 32 characters')
  end
end
