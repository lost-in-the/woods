# frozen_string_literal: true

require 'spec_helper'
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
  let(:pool) { instance_double('ActiveRecord::ConnectionPool') }
  let(:ar_base) { class_double('ActiveRecord::Base').as_stubbed_const }

  subject(:middleware) { described_class.new(->(_env) { [200, {}, []] }) }

  before do
    allow(ar_base).to receive(:connection_pool).and_return(pool)
    allow(ar_base).to receive(:descendants).and_return([])

    # Stub the heavy parts of server construction — we're only verifying the
    # connection-acquisition API surface, not the server wiring.
    server_double = instance_double('MCP::Server')
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
end
