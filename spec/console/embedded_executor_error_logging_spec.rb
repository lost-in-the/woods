# frozen_string_literal: true

require 'spec_helper'
require 'woods'
require 'woods/console/embedded_executor'

# L11. `EmbeddedExecutor#send_request` sanitizes the *client* response for an
# unexpected execution error (`sanitize_execution_error` returns the class name
# only) but wrote `error.message` verbatim to `Rails.logger`. PG/Mysql2 errors
# can embed the rejected SQL and, for some failure modes, the literal values in
# it — so an API key pasted into a WHERE clause, or a secret stored in a column
# named in a constraint violation, landed unscanned in the server log while the
# response path was scanned.
#
# Sibling of server_leak_scenarios_spec.rb, which proves the same posture on
# the response path; this file covers the log path.
RSpec.describe Woods::Console::EmbeddedExecutor do
  # Documented test fixtures — not real credentials. The `4eC39...` suffix is
  # Stripe's own documentation example, and AKIAIOSFODNN7EXAMPLE is AWS's.
  let(:stripe_live) { 'sk_live_4eC39HqLyjWDarjtT1zdp7dc' }
  let(:aws_key)     { 'AKIAIOSFODNN7EXAMPLE' }

  let(:registry) { { 'User' => %w[id email] } }
  let(:model_validator) { Woods::Console::ModelValidator.new(registry: registry) }

  # A logger that records what it was handed, standing in for Rails.logger.
  let(:recording_logger) do
    Class.new do
      attr_reader :warnings

      def initialize
        @warnings = []
      end

      def warn(message)
        @warnings << message
      end
    end.new
  end

  # SafeContext whose #execute raises the adapter error under test, so
  # send_request takes its generic StandardError branch.
  def executor_raising(error)
    safe_context = instance_double(Woods::Console::SafeContext)
    allow(safe_context).to receive(:execute).and_raise(error)
    described_class.new(model_validator: model_validator, safe_context: safe_context)
  end

  before do
    fake_rails = Module.new do
      class << self
        attr_accessor :logger
      end
    end
    fake_rails.logger = recording_logger
    stub_const('Rails', fake_rails)
  end

  def logged_text
    recording_logger.warnings.join("\n")
  end

  it 'credential-scans the adapter error text before the Rails.logger write' do
    error = StandardError.new("Mysql2::Error: Duplicate entry '#{stripe_live}' for key 'index_tokens'")
    response = executor_raising(error).send_request('tool' => 'count', 'params' => { 'model' => 'User' })

    expect(response['ok']).to be false
    expect(logged_text).not_to include(stripe_live)
    expect(logged_text).to include('[REDACTED]')
  end

  it 'scans every credential shape the response path scans' do
    error = StandardError.new("PG::CheckViolation: value #{aws_key} rejected")
    executor_raising(error).send_request('tool' => 'count', 'params' => { 'model' => 'User' })

    expect(logged_text).not_to include(aws_key)
    expect(logged_text).to include('[REDACTED]')
  end

  it 'still logs the error class and the Woods prefix so the line stays routable' do
    error = ArgumentError.new("token #{stripe_live} is malformed")
    executor_raising(error).send_request('tool' => 'count', 'params' => { 'model' => 'User' })

    expect(logged_text).to include('[Woods::Console] execution error:')
    expect(logged_text).to include('ArgumentError')
  end

  it 'leaves credential-free adapter detail intact for debugging' do
    error = StandardError.new('PG::UndefinedColumn: column users.nope does not exist')
    executor_raising(error).send_request('tool' => 'count', 'params' => { 'model' => 'User' })

    expect(logged_text).to include('column users.nope does not exist')
  end

  it 'never lets a scanner failure break the request path' do
    broken_scanner = instance_double(Woods::Console::CredentialScanner)
    allow(broken_scanner).to receive(:scan).and_raise('scanner down')
    allow(Woods::Console::CredentialScanner).to receive(:new).and_return(broken_scanner)
    error = StandardError.new("boom #{stripe_live}")

    response = executor_raising(error).send_request('tool' => 'count', 'params' => { 'model' => 'User' })

    expect(response['ok']).to be false
    expect(response['error_type']).to eq('execution')
    expect(logged_text).not_to include(stripe_live)
  end

  it 'keeps the client response free of the raw message either way' do
    error = StandardError.new("Mysql2::Error: #{stripe_live}")
    response = executor_raising(error).send_request('tool' => 'count', 'params' => { 'model' => 'User' })

    expect(response['error']).not_to include(stripe_live)
    expect(response['error']).to include('execution failed (details logged server-side)')
  end
end
