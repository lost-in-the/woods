# frozen_string_literal: true

require 'spec_helper'
require 'woods'
require 'woods/console/server'

# End-to-end wiring check for the Console defense-in-depth stack.
#
# The individual layers each have unit coverage (table_gate_spec,
# credential_scanner_spec, safe_context_spec). This spec proves the three
# layers thread through `Server.build_embedded` → `define_console_tool`
# → `send_to_bridge` correctly and in the intended order.
RSpec.describe 'Woods::Console::Server defense-in-depth wiring' do
  let(:registry) do
    {
      'User' => %w[id email name],
      'Authorization' => %w[id key value]
    }
  end
  let(:validator) { Woods::Console::ModelValidator.new(registry: registry) }
  let(:model_tables) { { 'User' => 'users', 'Authorization' => 'authorizations' } }
  let(:safe_context) { instance_double(Woods::Console::SafeContext) }
  let(:executor) { instance_double('Executor') }
  # Stripe's documented test-key example — allowlisted by GitHub secret scanning
  # and still matches `CredentialScanner`'s `stripe_secret_key` pattern.
  let(:stripe_secret) { 'sk_live_4eC39HqLyjWDarjtT1zdp7dc' }

  around do |example|
    previous = Woods.configuration
    Woods.configuration = Woods::Configuration.new
    example.run
  ensure
    Woods.configuration = previous
  end

  before do
    stub_const('Woods::Console::EmbeddedExecutor', Class.new { def initialize(**); end })
    allow(Woods::Console::EmbeddedExecutor).to receive(:new).and_return(executor)
    # Keep structured log lines out of test output unless an example opts in.
    require 'woods/observability/structured_logger'
    Woods::Console::Server.instance_variable_set(
      :@structured_logger,
      Woods::Observability::StructuredLogger.new(output: StringIO.new)
    )
  end

  after { Woods::Console::Server.instance_variable_set(:@structured_logger, nil) }

  def build(**overrides)
    Woods::Console::Server.build_embedded(
      model_validator: validator,
      safe_context: safe_context,
      model_tables: model_tables,
      **overrides
    )
  end

  def call_tool(server, tool_name, **args)
    tools = server.instance_variable_get(:@tools)
    tool_class = tools.fetch(tool_name)
    tool_class.call(**args, server_context: {})
  end

  def response_text(response)
    response.content.first[:text]
  end

  describe 'Layer 1 (TableGate)' do
    before do
      Woods.configuration.console_blocked_tables = %w[authorizations]
    end

    it 'rejects a model whose table is blocked before the executor is touched' do
      server = build
      expect(executor).not_to receive(:send_request)

      response = call_tool(server, 'console_find', model: 'Authorization', id: 1)

      expect(response).to be_error
      expect(response_text(response)).to include("table 'authorizations'")
    end

    it 'allows models whose tables are not blocked' do
      server = build
      allow(executor).to receive(:send_request).and_return(
        'ok' => true, 'result' => { 'record' => { 'id' => 1, 'email' => 'a@b.com' } }
      )

      response = call_tool(server, 'console_find', model: 'User', id: 1)

      expect(response).not_to be_error
      expect(response_text(response)).to include('a@b.com')
    end
  end

  describe 'Layer 2 (CredentialScanner)' do
    it 'redacts Stripe secret keys that slip through the bridge result' do
      server = build
      allow(executor).to receive(:send_request).and_return(
        'ok' => true,
        'result' => {
          'record' => {
            'id' => 1,
            'credentials' => stripe_secret
          }
        }
      )

      response = call_tool(server, 'console_find', model: 'User', id: 1)

      expect(response_text(response)).to include('[REDACTED]')
      expect(response_text(response)).not_to include(stripe_secret)
    end

    it 'can be disabled via configuration' do
      Woods.configuration.console_credential_scanning_enabled = false
      server = build
      allow(executor).to receive(:send_request).and_return(
        'ok' => true,
        'result' => { 'record' => { 'id' => 1, 'note' => stripe_secret } }
      )

      response = call_tool(server, 'console_find', model: 'User', id: 1)

      expect(response_text(response)).to include(stripe_secret)
    end

    it 'honors disabled_scanner_patterns to skip specific rules' do
      Woods.configuration.console_disabled_scanner_patterns = %i[stripe_secret_key]
      server = build
      allow(executor).to receive(:send_request).and_return(
        'ok' => true,
        'result' => {
          'record' => {
            'id' => 1,
            'stripe' => stripe_secret,
            'aws' => 'AKIAIOSFODNN7EXAMPLE'
          }
        }
      )

      response = call_tool(server, 'console_find', model: 'User', id: 1)
      text = response_text(response)

      expect(text).to include(stripe_secret)
      expect(text).to include('[REDACTED]')
      expect(text).not_to include('AKIAIOSFODNN7EXAMPLE')
    end
  end

  describe 'observability' do
    let(:log_output) { StringIO.new }
    let(:captured_lines) { log_output.string.each_line.map { |line| JSON.parse(line) } }

    before do
      require 'woods/observability/structured_logger'
      Woods::Console::Server.instance_variable_set(
        :@structured_logger,
        Woods::Observability::StructuredLogger.new(output: log_output)
      )
    end

    after { Woods::Console::Server.instance_variable_set(:@structured_logger, nil) }

    it 'emits console.credential_scan.hits when the scanner fires' do
      server = build
      allow(executor).to receive(:send_request).and_return(
        'ok' => true,
        'result' => { 'record' => { 'token' => stripe_secret } }
      )

      call_tool(server, 'console_find', model: 'User', id: 1)

      entry = captured_lines.find { |l| l['event'] == 'console.credential_scan.hits' }
      expect(entry).to include(
        'level' => 'warn',
        'tool' => 'find',
        'total' => 1,
        'counts' => { 'stripe_secret_key' => 1 }
      )
    end

    it 'does not emit when the scanner finds nothing' do
      server = build
      allow(executor).to receive(:send_request).and_return(
        'ok' => true, 'result' => { 'record' => { 'email' => 'clean@example.com' } }
      )

      call_tool(server, 'console_find', model: 'User', id: 1)

      expect(captured_lines).to be_empty
    end

    it 'emits console.table_gate.rejected when Layer 1 blocks a tool' do
      Woods.configuration.console_blocked_tables = %w[authorizations]
      server = build

      call_tool(server, 'console_find', model: 'Authorization', id: 1)

      entry = captured_lines.find { |l| l['event'] == 'console.table_gate.rejected' }
      expect(entry).to include(
        'level' => 'warn',
        'tool' => 'console_find',
        'model' => 'Authorization'
      )
      expect(entry['message']).to include('authorizations')
    end
  end

  describe 'Layer ordering — Layer 1 short-circuits before Layer 2 scans' do
    it 'does not even invoke the executor when a blocked table is referenced' do
      Woods.configuration.console_blocked_tables = %w[authorizations]
      server = build
      expect(executor).not_to receive(:send_request)

      response = call_tool(server, 'console_find', model: 'Authorization', id: 1)

      expect(response).to be_error
    end
  end
end
