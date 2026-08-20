# frozen_string_literal: true

require 'spec_helper'
require 'rack'
require 'mcp'
require 'woods'
require 'woods/console/rack_middleware'
require 'woods/console/safe_context'
require 'woods/console/model_validator'
require 'woods/observability/structured_logger'

# Stub Server so we don't pull in the full MCP transport stack.
unless defined?(Woods::Console::Server)
  module Woods
    module Console
      module Server
        def self.build_embedded(*); end
      end
    end
  end
end

# Regression: ActiveRecord::Base.connection is deprecated in Rails 7.2 and
# removed in 8.0. The middleware must hand SafeContext the connection pool
# (not a connection captured at build time) so each request leases and
# returns its own connection rather than pinning a single one for the
# lifetime of the process.
RSpec.describe Woods::Console::RackMiddleware do
  let(:pool) { double('ActiveRecord::ConnectionPool') }
  let(:ar_base) { class_double('ActiveRecord::Base').as_stubbed_const }
  let(:server_double) { instance_double(MCP::Server) }

  subject(:middleware) { described_class.new(->(_env) { [200, {}, []] }) }

  before do
    allow(ar_base).to receive(:connection_pool).and_return(pool)
    allow(ar_base).to receive(:descendants).and_return([])

    # Stub the heavy parts of server construction — we're only verifying the
    # connection-acquisition API surface, not the server wiring.
    allow(Woods::Console::Server).to receive(:build_embedded).and_return(server_double)
  end

  describe '#build_embedded_server' do
    it 'never invokes the deprecated ActiveRecord::Base.connection' do
      expect(ar_base).not_to receive(:connection)
      middleware.send(:build_embedded_server)
    end

    it 'never leases a connection at build time' do
      # Capturing a connection inside `with_connection { |c| c }` would
      # hand SafeContext a reference to a connection that has already
      # been checked back into the pool — exactly the bug this fix
      # closes.
      expect(pool).not_to receive(:with_connection)
      middleware.send(:build_embedded_server)
    end

    it 'passes the connection pool into SafeContext for per-request leasing' do
      allow(Woods::Console::SafeContext).to receive(:new).and_call_original

      middleware.send(:build_embedded_server)

      expect(Woods::Console::SafeContext).to have_received(:new)
        .with(hash_including(pool: pool))
    end
  end

  describe '#build_model_introspection' do
    let(:logger) { instance_double(Woods::Observability::StructuredLogger) }
    let(:bad_model) do
      m = class_double('BadModel')
      allow(m).to receive(:name).and_return('BadModel')
      allow(m).to receive(:abstract_class?).and_return(false)
      allow(m).to receive(:table_exists?).and_return(true)
      allow(m).to receive(:column_names).and_raise(StandardError, 'column boom')
      m
    end
    let(:good_model) do
      m = class_double('GoodModel')
      allow(m).to receive(:name).and_return('GoodModel')
      allow(m).to receive(:abstract_class?).and_return(false)
      allow(m).to receive(:table_exists?).and_return(true)
      allow(m).to receive(:column_names).and_return(['id'])
      allow(m).to receive(:table_name).and_return('good_models')
      allow(m).to receive(:reflect_on_all_associations).and_return([])
      m
    end

    before do
      allow(ar_base).to receive(:descendants).and_return([bad_model, good_model])
      middleware.instance_variable_set(:@structured_logger, logger)
      allow(logger).to receive(:debug)
    end

    it 'logs a debug event when a model raises during introspection' do
      middleware.send(:build_model_introspection)

      expect(logger).to have_received(:debug).with(
        'console.model_introspection.skipped',
        hash_including(model: 'BadModel', error_class: 'StandardError')
      )
    end

    it 'includes the error message in the debug payload' do
      middleware.send(:build_model_introspection)

      expect(logger).to have_received(:debug).with(
        'console.model_introspection.skipped',
        hash_including(error_message: 'column boom')
      )
    end

    it 'still includes the good model in the introspection result' do
      result = middleware.send(:build_model_introspection)

      expect(result[:registry]).to include('GoodModel')
    end

    it 'excludes the bad model from the introspection result' do
      result = middleware.send(:build_model_introspection)

      expect(result[:registry]).not_to include('BadModel')
    end
  end

  describe '#call' do
    subject(:middleware) { described_class.new(app) }

    let(:app_paths) { [] }
    let(:app) do
      paths = app_paths
      lambda do |env|
        paths << env['PATH_INFO']
        [200, { 'content-type' => 'text/html' }, ['app']]
      end
    end

    context 'when console_mcp_enabled is false (the default)' do
      before do
        Woods.configure # ensure a configuration exists regardless of spec order
        allow(Woods.configuration).to receive(:console_mcp_enabled).and_return(false)
      end

      # Regression for #183: the railtie mounts this middleware
      # unconditionally, so a host that never opted in must be completely
      # unaffected — pass through, do not answer 410 at the mounted path.
      it 'passes requests at the mounted path through to the app' do
        status, _headers, body = middleware.call('PATH_INFO' => '/mcp/console')
        expect(status).to eq(200)
        expect(body).to eq(['app'])
        expect(app_paths).to eq(['/mcp/console'])
      end
    end

    context 'when console_mcp_enabled is true' do
      before do
        Woods.configure # ensure a configuration exists regardless of spec order
        allow(Woods.configuration).to receive(:console_mcp_enabled).and_return(true)
      end

      it 'dispatches requests at the mounted path to the MCP transport' do
        transport = double('transport', handle_request: [200, {}, ['console']])
        allow(middleware).to receive(:ensure_transport).and_return(transport)

        _status, _headers, body = middleware.call('REQUEST_METHOD' => 'POST', 'PATH_INFO' => '/mcp/console')
        expect(body).to eq(['console'])
      end

      it 'strips stale session ids in the default stateless mode without mutating the Rack env' do
        received_request = nil
        transport = double('transport')
        allow(transport).to receive(:handle_request) do |request|
          received_request = request
          [200, {}, ['console']]
        end
        allow(middleware).to receive(:ensure_transport) do
          middleware.instance_variable_set(:@stateless_mode, true)
          transport
        end
        env = {
          'REQUEST_METHOD' => 'POST',
          'PATH_INFO' => '/mcp/console',
          'HTTP_MCP_SESSION_ID' => 'stale-session'
        }

        middleware.call(env)

        expect(received_request.env).not_to have_key('HTTP_MCP_SESSION_ID')
        expect(env['HTTP_MCP_SESSION_ID']).to eq('stale-session')
      end

      it 'preserves session ids when compatibility mode is explicit' do
        sessionful = described_class.new(app, stateless: false)
        received_request = nil
        transport = double('transport')
        allow(transport).to receive(:handle_request) do |request|
          received_request = request
          [200, {}, ['console']]
        end
        allow(sessionful).to receive(:ensure_transport) do
          sessionful.instance_variable_set(:@stateless_mode, false)
          transport
        end

        sessionful.call(
          'REQUEST_METHOD' => 'POST',
          'PATH_INFO' => '/mcp/console',
          'HTTP_MCP_SESSION_ID' => 'live-session'
        )

        expect(received_request.env['HTTP_MCP_SESSION_ID']).to eq('live-session')
      end

      it 'passes non-matching paths through to the app' do
        status, = middleware.call('PATH_INFO' => '/')
        expect(status).to eq(200)
        expect(app_paths).to eq(['/'])
      end
    end
  end

  describe '#ensure_transport' do
    let(:rails_app) { double('Rails.application', eager_load!: true) }
    let(:rails) { class_double('Rails', application: rails_app).as_stubbed_const }
    let(:transport) { instance_double(MCP::Server::Transports::StreamableHTTPTransport) }

    before do
      rails
      allow(middleware).to receive(:check_blocked_tables_config!)
      allow(middleware).to receive(:build_embedded_server).and_return(server_double)
      allow(server_double).to receive(:transport=)
    end

    it 'constructs stateless transport by default' do
      expect(MCP::Server::Transports::StreamableHTTPTransport).to receive(:new)
        .with(server_double, stateless: true)
        .and_return(transport)

      middleware.send(:ensure_transport)

      expect(middleware.instance_variable_get(:@stateless_mode)).to be true
    end

    it 'constructs session transport only with the compatibility setting' do
      sessionful = described_class.new(->(_env) { [200, {}, []] }, stateless: false)
      allow(sessionful).to receive(:check_blocked_tables_config!)
      allow(sessionful).to receive(:build_embedded_server).and_return(server_double)
      expect(MCP::Server::Transports::StreamableHTTPTransport).to receive(:new)
        .with(server_double, stateless: false)
        .and_return(transport)

      sessionful.send(:ensure_transport)

      expect(sessionful.instance_variable_get(:@stateless_mode)).to be false
    end
  end

  describe 'deferred embedded_read_tools (#183)' do
    it 'resolves a callable at server-build time, not construction time' do
      flag = false
      mw = described_class.new(->(_env) { [200, {}, []] }, embedded_read_tools: -> { flag })
      flag = true # set after construction — simulates config/initializers

      mw.send(:build_embedded_server)

      expect(Woods::Console::Server).to have_received(:build_embedded)
        .with(hash_including(read_tools_enabled: true))
    end

    it 'passes a plain boolean through unchanged' do
      mw = described_class.new(->(_env) { [200, {}, []] }, embedded_read_tools: true)

      mw.send(:build_embedded_server)

      expect(Woods::Console::Server).to have_received(:build_embedded)
        .with(hash_including(read_tools_enabled: true))
    end
  end

  describe '#check_blocked_tables_config!' do
    subject(:middleware) { described_class.new(->(_env) { [200, {}, []] }) }

    context 'when console_blocked_tables is non-empty' do
      before do
        allow(Woods.configuration).to receive(:console_blocked_tables)
          .and_return(%w[sessions])
      end

      it 'does nothing' do
        expect { middleware.send(:check_blocked_tables_config!) }.not_to raise_error
      end
    end

    context 'when console_blocked_tables is empty in a non-production environment' do
      before do
        allow(Woods.configuration).to receive(:console_blocked_tables).and_return([])

        rails_env = double('env', production?: false)
        rails_double = class_double('Rails').as_stubbed_const
        allow(rails_double).to receive(:env).and_return(rails_env)
      end

      it 'emits a warn instead of raising' do
        expect { middleware.send(:check_blocked_tables_config!) }.not_to raise_error
      end

      it 'includes the remediation hint in the warning' do
        warning = nil
        allow(middleware).to receive(:warn) { |msg| warning = msg }

        middleware.send(:check_blocked_tables_config!)

        expect(warning).to include('console_blocked_tables')
        expect(warning).to include('DEFAULT_CONSOLE_BLOCKED_TABLES')
      end
    end

    context 'when console_blocked_tables is empty in production' do
      before do
        allow(Woods.configuration).to receive(:console_blocked_tables).and_return([])

        rails_env = double('env', production?: true)
        rails_double = class_double('Rails').as_stubbed_const
        allow(rails_double).to receive(:env).and_return(rails_env)
      end

      it 'raises Woods::ConfigurationError' do
        expect { middleware.send(:check_blocked_tables_config!) }
          .to raise_error(Woods::ConfigurationError, /console_blocked_tables/)
      end

      it 'includes the remediation hint in the error message' do
        expect { middleware.send(:check_blocked_tables_config!) }
          .to raise_error(Woods::ConfigurationError, /DEFAULT_CONSOLE_BLOCKED_TABLES/)
      end
    end
  end
end
