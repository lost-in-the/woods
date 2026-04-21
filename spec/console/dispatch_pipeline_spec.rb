# frozen_string_literal: true

require 'spec_helper'
require 'mcp'
require 'woods/console/connection_manager'
require 'woods/console/sql_validator'
require 'woods/console/eval_guard'
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

  let(:ok_result) { { 'ok' => true, 'result' => { 'record' => { 'id' => 1 } } } }
  let(:error_result) { { 'ok' => false, 'error_type' => 'RuntimeError', 'error' => 'boom' } }

  let(:handler) { ->(args) { { tool: 'demo', args: args } } }
  let(:ctx) { Woods::Console::NullResponseContext.instance }

  def build_pipeline(conn:, ctx: Woods::Console::NullResponseContext.instance,
                     renderer: nil, logger: nil, integer_keys: [])
    described_class.new(
      tool_name: 'demo', handler: handler, integer_keys: integer_keys,
      conn_mgr: conn, ctx: ctx, renderer: renderer, logger: logger
    )
  end

  describe '#call' do
    it 'coerces integer-typed string args before dispatch' do
      conn = conn_mgr.new(ok_result)
      pipeline = build_pipeline(conn: conn, integer_keys: %i[limit])

      pipeline.call({ limit: '7' })

      expect(conn.calls.first['args']).to eq(limit: 7)
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
      logger = spy('logger')
      pipeline = build_pipeline(conn: conn, ctx: response_ctx, logger: logger)

      response = pipeline.call({})

      expect(response.content.first[:text]).to include('[REDACTED')
      expect(logger).to have_received(:warn).with('console.credential_scan.hits', anything)
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
      logger = spy('logger')
      pipeline = build_pipeline(conn: conn, ctx: response_ctx, logger: logger)

      response = pipeline.call({ sql: 'SELECT * FROM users' })

      expect(response.error?).to be(true)
      expect(response.content.first[:text]).to include('users')
      expect(logger).to have_received(:warn).with('console.table_gate.rejected', anything)
      expect(conn.calls).to be_empty
    end

    it 'translates SqlValidationError into an error response' do
      raising_handler = ->(_args) { raise Woods::Console::SqlValidationError, 'bad sql' }
      pipeline = described_class.new(
        tool_name: 'demo', handler: raising_handler, integer_keys: [],
        conn_mgr: conn_mgr.new(ok_result), ctx: ctx
      )

      response = pipeline.call({})
      expect(response.error?).to be(true)
      expect(response.content.first[:text]).to eq('bad sql')
    end

    it 'translates ConnectionError during dispatch into an error response' do
      exploding_conn = Class.new do
        def send_request(_request)
          raise Woods::Console::ConnectionError, 'pipe closed'
        end
      end.new

      pipeline = described_class.new(
        tool_name: 'demo', handler: handler, integer_keys: [],
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

    it 'defaults to NullResponseContext when no ctx is supplied' do
      pipeline = described_class.new(
        tool_name: 'demo', handler: handler, integer_keys: [],
        conn_mgr: conn_mgr.new(ok_result)
      )

      response = pipeline.call({ sql: 'SELECT * FROM whatever' })
      expect(response.error?).to be_falsey
    end
  end
end
