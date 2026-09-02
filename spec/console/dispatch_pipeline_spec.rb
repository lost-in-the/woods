# frozen_string_literal: true

require 'spec_helper'
require 'mcp'
require 'woods/console/connection_manager'
require 'woods/console/sql_validator'
require 'woods/console/eval_guard'
require 'woods/console/input_contract'
require 'woods/console/dispatch_pipeline'
require 'woods/console/response_context'
require 'woods/console/safe_context'
require 'woods/console/table_gate'
require 'woods/console/credential_scanner'

RSpec.describe Woods::Console::DispatchPipeline do
  let(:conn_mgr) do
    Class.new do
      attr_reader :calls

      def initialize(result)
        @result = result
        @calls = []
      end

      def send_request(request)
        @calls << request
        @result
      end
    end
  end

  # Hand-rolled recording logger. Each log call is captured as a data tuple so
  # specs can assert on observable log output without RSpec message spies.
  let(:recording_logger_class) do
    Class.new do
      attr_reader :events

      def initialize
        @events = []
      end

      def warn(event, payload = {})
        @events << { level: :warn, event: event, payload: payload }
      end

      def info(event, payload = {})
        @events << { level: :info, event: event, payload: payload }
      end
    end
  end

  let(:ok_result) { { 'ok' => true, 'result' => { 'record' => { 'id' => 1 } } } }
  let(:error_result) { { 'ok' => false, 'error_type' => 'RuntimeError', 'error' => 'boom' } }

  let(:handler) { ->(args) { { tool: 'demo', args: args } } }
  let(:ctx) { Woods::Console::NullResponseContext.instance }

  def build_pipeline(conn:, ctx: Woods::Console::NullResponseContext.instance,
                     renderer: nil, logger: nil, properties: {})
    described_class.new(
      tool_name: 'demo', handler: handler, properties: properties,
      conn_mgr: conn, ctx: ctx, renderer: renderer, logger: logger
    )
  end

  describe '#call' do
    it 'coerces integer-typed string args before dispatch' do
      conn = conn_mgr.new(ok_result)
      properties = { limit: { type: 'integer', minimum: 1, maximum: 25 } }
      pipeline = build_pipeline(conn: conn, properties: properties)

      pipeline.call({ limit: '7' })

      expect(conn.calls.first['args']).to eq(limit: 7)
    end

    it 'rejects malformed integer strings before dispatch' do
      properties = { limit: { type: 'integer', minimum: 1, maximum: 25 } }

      ['12junk', '1.5', ' 7'].each do |value|
        conn = conn_mgr.new(ok_result)
        response = build_pipeline(conn: conn, properties: properties).call(limit: value)

        expect(response).to be_error
        expect(response.content.first[:text]).to include('limit must be an integer')
        expect(conn.calls).to be_empty
      end
    end

    it 'rejects integers outside the schema bounds before dispatch' do
      properties = { limit: { type: 'integer', minimum: 1, maximum: 25 } }

      [0, -1, 26].each do |value|
        conn = conn_mgr.new(ok_result)
        response = build_pipeline(conn: conn, properties: properties).call(limit: value)

        expect(response).to be_error
        expect(response.content.first[:text]).to include('limit must be between 1 and 25')
        expect(conn.calls).to be_empty
      end
    end

    it 'returns a text MCP response for an ok bridge result' do
      conn = conn_mgr.new(ok_result)
      pipeline = build_pipeline(conn: conn)

      response = pipeline.call({})

      expect(response).to be_a(MCP::Tool::Response)
      expect(response.content.first[:text]).to include('"id": 1')
      expect(response.error?).to be_falsey
    end

    it 'applies Layer 3 redaction via the response context' do
      safe_ctx = Woods::Console::SafeContext.new(redacted_columns: %w[password])
      response_ctx = Woods::Console::ResponseContext.build(safe_ctx: safe_ctx)
      conn = conn_mgr.new('ok' => true,
                          'result' => { 'record' => { 'id' => 1, 'password' => 'secret' } })
      pipeline = build_pipeline(conn: conn, ctx: response_ctx)

      response = pipeline.call({})
      expect(response.content.first[:text]).to include('[REDACTED]')
      expect(response.content.first[:text]).not_to include('secret')
    end

    it 'applies Layer 2 credential scanning and logs hits' do
      scanner = Woods::Console::CredentialScanner.new
      response_ctx = Woods::Console::ResponseContext.build(credential_scanner: scanner)
      conn = conn_mgr.new('ok' => true, 'result' => 'token: sk_live_abcdefghijklmnopqrstuvwx')
      logger = recording_logger_class.new
      pipeline = build_pipeline(conn: conn, ctx: response_ctx, logger: logger)

      response = pipeline.call({})

      expect(response.content.first[:text]).to include('[REDACTED')
      credential_events = logger.events.select { |e| e[:event] == 'console.credential_scan.hits' }
      expect(credential_events).not_to be_empty
    end

    it 'renders via the renderer when provided' do
      renderer = Class.new do
        def render_default(result)
          "RENDERED: #{result.inspect}"
        end
      end.new
      conn = conn_mgr.new(ok_result)
      pipeline = build_pipeline(conn: conn, renderer: renderer)

      response = pipeline.call({})
      expect(response.content.first[:text]).to start_with('RENDERED:')
    end

    it 'returns an error MCP response for a failing bridge result' do
      conn = conn_mgr.new(error_result)
      pipeline = build_pipeline(conn: conn)

      response = pipeline.call({})
      expect(response.error?).to be(true)
      expect(response.content.first[:text]).to eq('RuntimeError: boom')
    end

    it 'translates TableGateError into an error response and logs the rejection' do
      gate = Woods::Console::TableGate.new(blocked_tables: %w[users], model_tables: {})
      response_ctx = Woods::Console::ResponseContext.build(table_gate: gate)
      conn = conn_mgr.new(ok_result)
      logger = recording_logger_class.new
      pipeline = build_pipeline(conn: conn, ctx: response_ctx, logger: logger)

      response = pipeline.call({ sql: 'SELECT * FROM users' })

      expect(response.error?).to be(true)
      expect(response.content.first[:text]).to include('users')
      rejection_events = logger.events.select { |e| e[:event] == 'console.table_gate.rejected' }
      expect(rejection_events).not_to be_empty
      expect(conn.calls).to be_empty
    end

    it 'translates SqlValidationError into an error response' do
      raising_handler = ->(_args) { raise Woods::Console::SqlValidationError, 'bad sql' }
      pipeline = described_class.new(
        tool_name: 'demo', handler: raising_handler, properties: {},
        conn_mgr: conn_mgr.new(ok_result), ctx: ctx
      )

      response = pipeline.call({})
      expect(response.error?).to be(true)
      expect(response.content.first[:text]).to eq('bad sql')
    end

    it 'credential-scans errors raised before an executor request exists' do
      credential = 'sk_live_abcdefghijklmnopqrstuvwx'
      raising_handler = lambda do |_args|
        raise Woods::Console::SqlValidationError, "invalid SQL near #{credential}"
      end
      scanner = Woods::Console::CredentialScanner.new
      response_ctx = Woods::Console::ResponseContext.build(credential_scanner: scanner)
      logger = recording_logger_class.new
      pipeline = described_class.new(
        tool_name: 'console_sql', handler: raising_handler, properties: {},
        conn_mgr: conn_mgr.new(ok_result), ctx: response_ctx, logger: logger
      )

      response = pipeline.call({})

      expect(response).to be_error
      expect(response.content.first[:text]).to include('[REDACTED]')
      expect(response.content.first[:text]).not_to include(credential)
      event = logger.events.find { |entry| entry[:event] == 'console.credential_scan.hits' }
      expect(event.dig(:payload, :tool)).to eq('sql')
    end

    it 'translates ConnectionError during dispatch into an error response' do
      exploding_conn = Class.new do
        def send_request(_request)
          raise Woods::Console::ConnectionError, 'pipe closed'
        end
      end.new

      pipeline = described_class.new(
        tool_name: 'demo', handler: handler, properties: {},
        conn_mgr: exploding_conn, ctx: ctx
      )

      response = pipeline.call({})
      expect(response.error?).to be(true)
      expect(response.content.first[:text]).to include('Connection error: pipe closed')
    end

    it 'never crashes when the logger raises during credential-hit logging' do
      scanner = Woods::Console::CredentialScanner.new
      response_ctx = Woods::Console::ResponseContext.build(credential_scanner: scanner)
      conn = conn_mgr.new('ok' => true, 'result' => 'token: sk_live_abcdefghijklmnopqrstuvwx')
      broken_logger = Class.new { def warn(*) = raise('telemetry down') }.new
      pipeline = build_pipeline(conn: conn, ctx: response_ctx, logger: broken_logger)

      expect { pipeline.call({}) }.not_to raise_error
    end

    # ── Unexpected raises stay inside the pipeline (L9) ──────────────────
    #
    # The rescue list named five known error classes, so anything else — a
    # renderer NoMethodError, an encoding oddity, a handler bug — escaped into
    # whatever the `mcp` gem does with a raising tool block, potentially
    # echoing `Class: message` to the client. Executor errors are already
    # sanitized (EmbeddedExecutor#sanitize_execution_error); the pipeline's own
    # bugs must land on the same footing: a sanitized tool error carrying no
    # exception text, credential-scanned like every other early error.
    describe 'unexpected exceptions' do
      it 'renders a renderer NoMethodError as a sanitized tool error' do
        broken_renderer = Class.new do
          def render_default(_result)
            nil.no_such_method
          end
        end.new
        conn = conn_mgr.new(ok_result)
        pipeline = build_pipeline(conn: conn, renderer: broken_renderer)

        response = nil
        expect { response = pipeline.call({}) }.not_to raise_error
        expect(response).to be_error
        expect(response.content.first[:text]).to include('demo')
        expect(response.content.first[:text]).not_to include('no_such_method')
        expect(response.content.first[:text]).not_to include('NoMethodError')
      end

      it 'renders an unexpected handler raise as a sanitized tool error' do
        raising_handler = ->(_args) { raise ArgumentError, 'password=hunter2' }
        pipeline = described_class.new(
          tool_name: 'demo', handler: raising_handler, properties: {},
          conn_mgr: conn_mgr.new(ok_result), ctx: ctx
        )

        response = nil
        expect { response = pipeline.call({}) }.not_to raise_error
        expect(response).to be_error
        expect(response.content.first[:text]).not_to include('hunter2')
      end

      it 'credential-scans the sanitized text through the early-error path' do
        credential = 'sk_live_abcdefghijklmnopqrstuvwx'
        raising_handler = ->(_args) { raise ArgumentError, credential }
        scanner = Woods::Console::CredentialScanner.new
        response_ctx = Woods::Console::ResponseContext.build(credential_scanner: scanner)
        pipeline = described_class.new(
          tool_name: 'console_sql', handler: raising_handler, properties: {},
          conn_mgr: conn_mgr.new(ok_result), ctx: response_ctx
        )

        response = pipeline.call({})

        expect(response).to be_error
        expect(response.content.first[:text]).not_to include(credential)
      end

      it 'logs the unexpected failure so operators can still debug it' do
        raising_handler = ->(_args) { raise ArgumentError, 'boom' }
        logger = recording_logger_class.new
        pipeline = described_class.new(
          tool_name: 'demo', handler: raising_handler, properties: {},
          conn_mgr: conn_mgr.new(ok_result), ctx: ctx, logger: logger
        )

        pipeline.call({})

        event = logger.events.find { |entry| entry[:event] == 'console.dispatch.unexpected_error' }
        expect(event).not_to be_nil
        expect(event.dig(:payload, :tool)).to eq('demo')
        expect(event.dig(:payload, :error_class)).to eq('ArgumentError')
      end

      it 'still lets a non-StandardError abort the process' do
        exploding_handler = ->(_args) { raise NotImplementedError, 'interface stub' }
        pipeline = described_class.new(
          tool_name: 'demo', handler: exploding_handler, properties: {},
          conn_mgr: conn_mgr.new(ok_result), ctx: ctx
        )

        expect { pipeline.call({}) }.to raise_error(NotImplementedError)
      end
    end

    it 'defaults to NullResponseContext when no ctx is supplied' do
      pipeline = described_class.new(
        tool_name: 'demo', handler: handler, properties: {},
        conn_mgr: conn_mgr.new(ok_result)
      )

      response = pipeline.call({ sql: 'SELECT * FROM whatever' })
      expect(response.error?).to be_falsey
    end
  end
end
