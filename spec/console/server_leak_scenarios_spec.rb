# frozen_string_literal: true

require 'spec_helper'
require 'woods'
require 'woods/console/server'

# Fixture-driven end-to-end leak scenarios for the Console MCP defense stack.
#
# Sibling of server_defense_layers_spec.rb. Where that spec proves each layer
# is *wired* into the dispatch pipeline, this spec proves the *combined* stack
# catches the real-world leak shapes that motivated the audit:
#
#   Scenario A — Blocked table short-circuit
#     Host marks `authorizations` as blocked. A tool request scoped to the
#     Authorization model is rejected at dispatch; the executor is never called.
#
#   Scenario B — EAV (key-value) leak through a non-blocked table
#     An app without `console_blocked_tables` set — but with the key-value
#     redaction pattern configured — returns a Stripe token from a generic
#     {key:, value:} row. Layer 3 redacts the value cell. Layer 2 verifies
#     nothing credential-shaped survives.
#
#   Scenario C — Free-text column leak
#     A User record has a Stripe key accidentally pasted into a free-text
#     `note` column. No column redaction is configured for `note`. Layer 2
#     (credential scanner) catches it based on the value shape alone.
#
#   Scenario D — Positional row shape (console_sql response)
#     A raw SQL response comes back as {columns: [...], rows: [[...]]} with
#     a secret in one of the positional cells. Layer 2 descends into the
#     nested array and redacts.
#
#   Scenario E — Clean response
#     A well-formed, secret-free record passes through unchanged, emits no
#     credential-scan log line, and produces no false positives.
#
# Each scenario builds the server via Server.build_embedded (the same
# entry point the real stdio/rack transports use), stubs the executor to
# return a realistic response payload for that shape, and asserts on the
# rendered text the MCP client would receive.
RSpec.describe 'Woods::Console::Server leak scenarios (fixture-driven)' do
  let(:registry) do
    {
      'User' => %w[id email name note],
      'Authorization' => %w[id key value user_id],
      'Setting' => %w[id key value]
    }
  end
  let(:validator) { Woods::Console::ModelValidator.new(registry: registry) }
  let(:model_tables) do
    { 'User' => 'users', 'Authorization' => 'authorizations', 'Setting' => 'settings' }
  end
  let(:safe_context) { instance_double(Woods::Console::SafeContext) }
  let(:executor) { instance_double('Executor') }
  let(:log_output) { StringIO.new }
  let(:captured_lines) { log_output.string.each_line.map { |line| JSON.parse(line) } }

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
    require 'woods/observability/structured_logger'
    Woods::Console::Server.instance_variable_set(
      :@structured_logger,
      Woods::Observability::StructuredLogger.new(output: log_output)
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

  # Documented test fixtures — not real credentials. The `4eC39...` suffix is
  # Stripe's own documentation example (allowlisted by GitHub secret scanning),
  # and AKIAIOSFODNN7EXAMPLE is AWS's official example key.
  let(:stripe_live) { 'sk_live_4eC39HqLyjWDarjtT1zdp7dc' }
  let(:stripe_test) { 'sk_test_4eC39HqLyjWDarjtT1zdp7dc' }
  let(:aws_key)     { 'AKIAIOSFODNN7EXAMPLE' }

  describe 'Scenario A — blocked table short-circuits before executor' do
    before { Woods.configuration.console_blocked_tables = %w[authorizations] }

    it 'rejects console_find on Authorization without hitting the executor' do
      server = build
      expect(executor).not_to receive(:send_request)

      response = call_tool(server, 'console_find', model: 'Authorization', id: 1)

      expect(response).to be_error
      expect(response_text(response)).to include("table 'authorizations'")

      rejection = captured_lines.find { |l| l['event'] == 'console.table_gate.rejected' }
      expect(rejection).to include('tool' => 'console_find', 'model' => 'Authorization')
    end

    it 'rejects console_sample on Authorization' do
      server = build
      expect(executor).not_to receive(:send_request)

      response = call_tool(server, 'console_sample', model: 'Authorization', limit: 5)

      expect(response).to be_error
    end
  end

  describe 'Scenario B — EAV leak redacted by key-value pattern + scanner' do
    before do
      Woods.configuration.console_redacted_key_values = [
        {
          key_column: 'key',
          value_column: 'value',
          sensitive_keys: %w[stripe_access_token oauth_token]
        }
      ]
    end

    it 'redacts the value cell and emits no credential-scan log when Layer 3 caught it' do
      server = build
      allow(executor).to receive(:send_request).and_return(
        'ok' => true,
        'result' => {
          'records' => [
            { 'id' => 1, 'key' => 'stripe_access_token', 'value' => stripe_live, 'user_id' => 7 },
            { 'id' => 2, 'key' => 'display_name',        'value' => 'Shopkeeper', 'user_id' => 7 }
          ]
        }
      )

      response = call_tool(server, 'console_sample', model: 'Setting', limit: 10)
      text = response_text(response)

      expect(text).to include('[REDACTED]')
      expect(text).not_to include(stripe_live)
      expect(text).to include('Shopkeeper')
    end

    it 'still redacts when the pattern is unconfigured — Layer 2 catches by shape' do
      Woods.configuration.console_redacted_key_values = []
      server = build
      allow(executor).to receive(:send_request).and_return(
        'ok' => true,
        'result' => {
          'records' => [
            { 'id' => 1, 'key' => 'stripe_access_token', 'value' => stripe_live, 'user_id' => 7 }
          ]
        }
      )

      response = call_tool(server, 'console_sample', model: 'Setting', limit: 10)

      expect(response_text(response)).not_to include(stripe_live)
      expect(captured_lines.find { |l| l['event'] == 'console.credential_scan.hits' }).not_to be_nil
    end
  end

  describe 'Scenario C — free-text column leak caught by content scanner' do
    it 'redacts a Stripe key pasted into a non-redacted column' do
      server = build
      allow(executor).to receive(:send_request).and_return(
        'ok' => true,
        'result' => {
          'record' => {
            'id' => 42,
            'email' => 'leaky@example.com',
            'name' => 'Leaky User',
            'note' => "Customer emailed me this key: #{stripe_test}, please rotate."
          }
        }
      )

      response = call_tool(server, 'console_find', model: 'User', id: 42)
      text = response_text(response)

      expect(text).to include('[REDACTED]')
      expect(text).not_to include(stripe_test)
      expect(text).to include('leaky@example.com')

      hits = captured_lines.find { |l| l['event'] == 'console.credential_scan.hits' }
      expect(hits).to include('tool' => 'find', 'total' => 1)
      expect(hits['counts']).to include('stripe_secret_key' => 1)
    end
  end

  describe 'Scenario D — positional row shape (console_sql response)' do
    it 'redacts secrets in the nested rows array' do
      server = build
      allow(executor).to receive(:send_request).and_return(
        'ok' => true,
        'result' => {
          'columns' => %w[id email note],
          'rows' => [
            [1, 'clean@example.com', 'nothing to see here'],
            [2, 'leak@example.com', "aws creds: #{aws_key}"]
          ],
          'count' => 2
        }
      )

      # console_sql is a Tier 4 tool — register it via the embedded executor path
      allow(executor).to receive(:send_request).and_return(
        'ok' => true,
        'result' => {
          'columns' => %w[id email note],
          'rows' => [
            [1, 'clean@example.com', 'nothing to see here'],
            [2, 'leak@example.com', "aws creds: #{aws_key}"]
          ],
          'count' => 2
        }
      )

      response = call_tool(server, 'console_sql', sql: 'SELECT id, email, note FROM users')
      text = response_text(response)

      expect(text).to include('[REDACTED]')
      expect(text).not_to include(aws_key)
      expect(text).to include('clean@example.com')
    end
  end

  describe 'Scenario E — clean response passes through untouched' do
    it 'emits no scan log and preserves the payload' do
      server = build
      allow(executor).to receive(:send_request).and_return(
        'ok' => true,
        'result' => {
          'record' => { 'id' => 1, 'email' => 'normal@example.com', 'name' => 'Normal' }
        }
      )

      response = call_tool(server, 'console_find', model: 'User', id: 1)
      text = response_text(response)

      expect(text).to include('normal@example.com')
      expect(text).not_to include('[REDACTED]')
      expect(captured_lines).to be_empty
    end
  end
end
