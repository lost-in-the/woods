# frozen_string_literal: true

require 'spec_helper'
require 'rack'
require 'woods'
require 'woods/railtie_support'
require 'woods/mcp/bearer_auth'
require 'woods/mcp/origin_guard'
require 'woods/console/rack_middleware'

# The railtie itself (Woods::Railtie < Rails::Railtie) cannot load without
# railties, and these unit specs run without a booted Rails app — that limit
# is deliberate (see CLAUDE.md). What CAN be covered here, and is:
#
#   * Woods::RailtieSupport — the request-time procs the railtie hands to
#     the console middlewares, and the after_initialize verification that
#     replaces the old boot-time flag checks (#183).
#   * A faithful mirror of the middleware stack the 'woods.console_mcp'
#     initializer mounts, driven with plain Rack env hashes.
#   * A mirror of the 'woods.session_tracer' initializer body (kept in sync
#     with railtie.rb).
#
# The actual `app.middleware.use` wiring and initializer ordering are only
# observable in a booted host app (verified against Rails 8.1 for #183).
RSpec.describe 'Woods::Railtie support logic' do
  before do
    Woods.configuration = nil
    Woods::RailtieSupport.console_mounted_path = nil
    Woods::RailtieSupport.session_tracer_state = nil
  end

  after do
    Woods.configuration = nil
    Woods::RailtieSupport.console_mounted_path = nil
    Woods::RailtieSupport.session_tracer_state = nil
  end

  describe 'request-time configuration procs (#183 regression)' do
    # Railtie initializers run before config/initializers — a flag set there
    # used to be a silent no-op because the railtie read it eagerly. The
    # procs must observe configuration changes made AFTER their creation.
    it 'console_enabled_proc reflects a flag set after the proc was created' do
      enabled = Woods::RailtieSupport.console_enabled_proc
      expect(enabled.call).to be(false)

      Woods.configure { |c| c.console_mcp_enabled = true }
      expect(enabled.call).to be(true)
    end

    it 'console_token_proc reflects a token set after the proc was created' do
      token_proc = Woods::RailtieSupport.console_token_proc
      Woods.configure { |c| c.console_mcp_token = 'a' * 40 }

      expect(token_proc.call).to eq('a' * 40)
    end

    it 'console_allowed_origins_proc reflects origins set after the proc was created' do
      origins_proc = Woods::RailtieSupport.console_allowed_origins_proc
      Woods.configure { |c| c.console_mcp_allowed_origins = ['https://app.example.com'] }

      expect(origins_proc.call).to eq(['https://app.example.com'])
    end

    it 'console_read_tools_proc reflects the flag set after the proc was created' do
      read_tools_proc = Woods::RailtieSupport.console_read_tools_proc
      Woods.configure { |c| c.console_embedded_read_tools = true }

      expect(read_tools_proc.call).to be(true)
    end
  end

  describe 'the mounted console stack (mirror of the woods.console_mcp initializer)' do
    let(:seen_paths) { [] }
    let(:host_app) do
      paths = seen_paths
      lambda do |env|
        paths << env['PATH_INFO']
        [200, { 'content-type' => 'text/html' }, ['host app']]
      end
    end

    # Mirror of the railtie initializer body — keep in sync with railtie.rb.
    def build_console_stack(inner_app)
      path = Woods::RailtieSupport.config.console_mcp_path
      Woods::RailtieSupport.console_mounted_path = path
      enabled = Woods::RailtieSupport.console_enabled_proc

      rack_console = Woods::Console::RackMiddleware.new(
        inner_app,
        path: path,
        embedded_read_tools: Woods::RailtieSupport.console_read_tools_proc
      )
      bearer = Woods::MCP::BearerAuth.new(
        rack_console,
        token: Woods::RailtieSupport.console_token_proc,
        path: path, enabled: enabled
      )
      Woods::MCP::OriginGuard.new(
        bearer,
        allowed_origins: Woods::RailtieSupport.console_allowed_origins_proc,
        path: path, enabled: enabled
      )
    end

    def request(stack, path, headers = {})
      stack.call({ 'REQUEST_METHOD' => 'GET', 'PATH_INFO' => path }.merge(headers))
    end

    context 'when the app never configured Woods (defaults)' do
      it 'leaves GET / completely untouched' do
        status, _headers, body = request(build_console_stack(host_app), '/')
        expect(status).to eq(200)
        expect(body).to eq(['host app'])
      end

      it 'leaves GET / untouched even with a non-loopback Host and no bearer header' do
        stack = build_console_stack(host_app)
        status, = request(stack, '/', 'HTTP_HOST' => 'app.production.example.com')
        expect(status).to eq(200)
      end

      it 'passes even the console path through to the app while disabled' do
        status, _headers, body = request(build_console_stack(host_app), '/mcp/console')
        expect(status).to eq(200)
        expect(body).to eq(['host app'])
        expect(seen_paths).to eq(['/mcp/console'])
      end
    end

    context 'when the console is enabled after the stack was mounted (config/initializers timing)' do
      let(:token) { 'c' * 40 }

      def enable_console!
        Woods.configure do |c|
          c.console_mcp_enabled = true
          c.console_mcp_token = token
        end
      end

      it 'guards the console path with 401 when the bearer header is missing' do
        stack = build_console_stack(host_app) # mounted BEFORE the config below
        enable_console!

        status, = request(stack, '/mcp/console')
        expect(status).to eq(401)
        expect(seen_paths).to be_empty
      end

      it 'still leaves GET / untouched' do
        stack = build_console_stack(host_app)
        enable_console!

        status, = request(stack, '/')
        expect(status).to eq(200)
      end

      it 'rejects a disallowed Origin at the console path' do
        stack = build_console_stack(host_app)
        enable_console!

        status, = request(stack, '/mcp/console', 'HTTP_ORIGIN' => 'http://evil.example.com')
        expect(status).to eq(403)
      end

      it 'serves the console for an authorized request' do
        stack = build_console_stack(host_app)
        enable_console!

        transport = double('transport', handle_request: [200, {}, ['console']])
        # Reach through the stack to the RackMiddleware instance and stub the
        # transport so the spec does not boot the embedded MCP server.
        bearer = stack.instance_variable_get(:@app)
        rack_console = bearer.instance_variable_get(:@app)
        allow(rack_console).to receive(:ensure_transport).and_return(transport)

        status, _headers, body = request(
          stack, '/mcp/console', 'HTTP_AUTHORIZATION' => "Bearer #{token}"
        )
        expect(status).to eq(200)
        expect(body).to eq(['console'])
      end
    end
  end

  describe 'Woods::RailtieSupport.verify_console_configuration!' do
    before { allow(Woods::RailtieSupport).to receive(:warn) }

    context 'with the console disabled (default)' do
      it 'neither raises nor warns' do
        expect { Woods::RailtieSupport.verify_console_configuration!(production: true) }
          .not_to raise_error
        expect(Woods::RailtieSupport).not_to have_received(:warn)
      end
    end

    context 'with the console enabled and no token' do
      before { Woods.configure { |c| c.console_mcp_enabled = true } }

      it 'raises in production' do
        expect { Woods::RailtieSupport.verify_console_configuration!(production: true) }
          .to raise_error(Woods::ConfigurationError, /console_mcp_token is not set/)
      end

      it 'warns (requests fail closed with 401) outside production' do
        Woods::RailtieSupport.verify_console_configuration!(production: false)

        expect(Woods::RailtieSupport).to have_received(:warn)
          .with(a_string_including('refused (401)'))
      end
    end

    context 'with the console enabled and a too-short token' do
      before do
        Woods.configure do |c|
          c.console_mcp_enabled = true
          c.console_mcp_token = 'short'
        end
      end

      it 'raises in every environment' do
        expect { Woods::RailtieSupport.verify_console_configuration!(production: false) }
          .to raise_error(Woods::ConfigurationError, /shorter than 32/)
      end
    end

    context 'with the console enabled and a usable token' do
      before do
        Woods.configure do |c|
          c.console_mcp_enabled = true
          c.console_mcp_token = 'd' * 40
        end
      end

      it 'neither raises nor warns' do
        expect { Woods::RailtieSupport.verify_console_configuration!(production: true) }
          .not_to raise_error
        expect(Woods::RailtieSupport).not_to have_received(:warn)
      end
    end

    context 'when console_mcp_path was changed after the stack was mounted' do
      before do
        Woods::RailtieSupport.console_mounted_path = '/mcp/console'
        Woods.configure { |c| c.console_mcp_path = '/internal/console' }
      end

      it 'warns that the path change did not take effect' do
        Woods::RailtieSupport.verify_console_configuration!(production: false)

        expect(Woods::RailtieSupport).to have_received(:warn)
          .with(a_string_including('config/application.rb'))
      end
    end
  end

  describe 'Woods::RailtieSupport.verify_session_tracer_configuration!' do
    before { allow(Woods::RailtieSupport).to receive(:warn) }

    context 'when the flag was set too late for the railtie to mount (state nil)' do
      before { Woods.configure { |c| c.session_tracer_enabled = true } }

      it 'warns with the config/application.rb remediation' do
        Woods::RailtieSupport.verify_session_tracer_configuration!

        expect(Woods::RailtieSupport).to have_received(:warn)
          .with(a_string_including('config/application.rb'))
      end
    end

    context 'when the middleware was mounted' do
      before do
        Woods.configure { |c| c.session_tracer_enabled = true }
        Woods::RailtieSupport.session_tracer_state = :mounted
      end

      it 'does not warn' do
        Woods::RailtieSupport.verify_session_tracer_configuration!
        expect(Woods::RailtieSupport).not_to have_received(:warn)
      end
    end

    context 'when the production guard skipped mounting (already warned at boot)' do
      before do
        Woods.configure { |c| c.session_tracer_enabled = true }
        Woods::RailtieSupport.session_tracer_state = :skipped_production
      end

      it 'does not warn again' do
        Woods::RailtieSupport.verify_session_tracer_configuration!
        expect(Woods::RailtieSupport).not_to have_received(:warn)
      end
    end

    context 'when the tracer is disabled' do
      it 'does not warn' do
        Woods::RailtieSupport.verify_session_tracer_configuration!
        expect(Woods::RailtieSupport).not_to have_received(:warn)
      end
    end
  end
end

# Mirror of the 'woods.session_tracer' initializer body — kept in sync with
# railtie.rb. The session tracer middleware requires a store at construction,
# so (unlike the console stack) it stays conditionally mounted; the
# after_initialize warning covered above handles the too-late-flag case.
RSpec.describe 'Woods::Railtie session_tracer initializer' do
  # A minimal double that records middleware.use calls
  let(:middleware_stack) { [] }
  let(:app) do
    stack = middleware_stack
    double('app').tap do |d|
      allow(d).to receive(:middleware) do
        m = double('middleware')
        allow(m).to receive(:use) { |klass, **opts| stack << { klass: klass, opts: opts } }
        m
      end
    end
  end

  # Rebuild a fresh configuration for every example
  before do
    Woods.configuration = nil
    Woods::RailtieSupport.session_tracer_state = nil
  end

  after do
    Woods.configuration = nil
    Woods::RailtieSupport.session_tracer_state = nil
  end

  # Run the initializer block directly (mirrors what Rails calls during boot)
  def run_initializer(config, rails_env:, logger: nil)
    # Simulate the block body — kept in sync with railtie.rb
    Woods::RailtieSupport.session_tracer_state = nil
    return unless config.session_tracer_enabled

    if rails_env == 'production' && !config.session_tracer_allow_production
      warn_production_guard(logger)
      Woods::RailtieSupport.session_tracer_state = :skipped_production
      return
    end

    require 'woods/session_tracer/middleware'

    app.middleware.use(
      Woods::SessionTracer::Middleware,
      store: config.session_store,
      session_id_proc: config.session_id_proc,
      exclude_paths: config.session_exclude_paths
    )
    Woods::RailtieSupport.session_tracer_state = :mounted
  end

  # Mirrors the production-guard warning branch in railtie.rb
  def warn_production_guard(logger)
    msg = '[Woods] session tracer disabled in production; ' \
          'set `session_tracer_allow_production = true` to opt in.'
    if logger
      logger.warn(msg)
    else
      warn msg
    end
  end

  describe 'production environment — tracer enabled, no override' do
    before do
      Woods.configure do |c|
        c.session_tracer_enabled = true
        # session_tracer_allow_production is false by default
      end
    end

    it 'does not install the middleware' do
      run_initializer(Woods.configuration, rails_env: 'production')
      expect(middleware_stack).to be_empty
    end

    it 'records the skip so after_initialize does not re-warn' do
      logger = instance_double('Logger', warn: nil)
      run_initializer(Woods.configuration, rails_env: 'production', logger: logger)
      expect(Woods::RailtieSupport.session_tracer_state).to eq(:skipped_production)
    end

    it 'emits a warning to the provided logger' do
      logger = instance_double('Logger')
      expect(logger).to receive(:warn).with(a_string_including('session tracer disabled in production'))
      run_initializer(Woods.configuration, rails_env: 'production', logger: logger)
    end

    it 'emits the opt-in instruction in the warning' do
      logger = instance_double('Logger')
      expect(logger).to receive(:warn).with(a_string_including('session_tracer_allow_production = true'))
      run_initializer(Woods.configuration, rails_env: 'production', logger: logger)
    end
  end

  describe 'production environment — tracer enabled with explicit opt-in' do
    before do
      Woods.configure do |c|
        c.session_tracer_enabled = true
        c.session_tracer_allow_production = true
      end
    end

    it 'installs the middleware' do
      run_initializer(Woods.configuration, rails_env: 'production')
      expect(middleware_stack.map { |e| e[:klass] }).to include(Woods::SessionTracer::Middleware)
    end
  end

  describe 'development environment — tracer enabled' do
    before do
      Woods.configure do |c|
        c.session_tracer_enabled = true
      end
    end

    it 'installs the middleware unchanged' do
      run_initializer(Woods.configuration, rails_env: 'development')
      expect(middleware_stack.map { |e| e[:klass] }).to include(Woods::SessionTracer::Middleware)
    end

    it 'records the mount so after_initialize does not warn' do
      run_initializer(Woods.configuration, rails_env: 'development')
      expect(Woods::RailtieSupport.session_tracer_state).to eq(:mounted)
    end
  end

  describe 'production environment — tracer disabled' do
    before do
      Woods.configure do |c|
        c.session_tracer_enabled = false
      end
    end

    it 'does not install the middleware' do
      run_initializer(Woods.configuration, rails_env: 'production')
      expect(middleware_stack).to be_empty
    end
  end
end
