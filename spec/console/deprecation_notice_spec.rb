# frozen_string_literal: true

require 'spec_helper'
require 'woods'
require 'woods/console/server'
require 'woods/console/rack_middleware'

RSpec.describe 'Console MCP deprecation notice' do
  let(:notice) { /^\[woods\] DEPRECATED: The Console MCP server .*removed in Woods 3\.0\b/ }
  let(:validator) { Woods::Console::ModelValidator.new(registry: {}) }
  let(:safe_context) { Woods::Console::SafeContext.new(connection: double('Connection')) }

  before do
    Woods::Deprecation.reset!
    Woods.configuration = Woods::Configuration.new.tap { |c| c.console_credential_defense_enabled = false }
  end

  after { Woods.configuration = nil }

  def stderr_of
    original = $stderr
    $stderr = StringIO.new
    yield
    $stderr.string
  ensure
    $stderr = original
  end

  def build
    Woods::Console::Server.build_embedded(model_validator: validator, safe_context: safe_context)
  end

  describe 'Server.build_embedded' do
    it 'warns once on stderr, naming Woods 3.0' do
      err = stderr_of { build }

      expect(err.lines.grep(/DEPRECATED/).size).to eq(1)
      expect(err).to match(notice)
    end

    it 'stays silent on a second build in the same process' do
      stderr_of { build }

      expect { build }.not_to output.to_stderr
    end

    it 'never writes the notice to stdout, the stdio protocol channel' do
      expect { stderr_of { build } }.not_to output.to_stdout
    end
  end

  describe Woods::Console::RackMiddleware do
    let(:app) { ->(_env) { [200, {}, ['app']] } }
    let(:ar_base) { class_double('ActiveRecord::Base').as_stubbed_const }

    before do
      allow(ar_base).to receive_messages(connection_pool: double('Pool'), descendants: [])
    end

    it 'warns once when it builds the Console server' do
      middleware = described_class.new(app)

      err = stderr_of { 2.times { middleware.send(:build_embedded_server) } }

      expect(err.lines.grep(/DEPRECATED/).size).to eq(1)
      expect(err).to match(notice)
    end

    it 'stays silent when mounted and passing requests through while the Console is disabled' do
      expect do
        middleware = described_class.new(app)
        middleware.call('PATH_INFO' => '/mcp/console')
      end.not_to output.to_stderr
    end
  end

  describe 'Configuration#console_mcp_enabled=' do
    it 'prints nothing when the Console is only switched on, so opted-in Rails processes stay quiet' do
      expect { Woods::Configuration.new.console_mcp_enabled = true }.not_to output.to_stderr
    end

    it 'leaves the notice to the server start' do
      err = stderr_of do
        Woods.configuration.console_mcp_enabled = true
        build
      end

      expect(err.lines.grep(/DEPRECATED/).size).to eq(1)
    end
  end
end
