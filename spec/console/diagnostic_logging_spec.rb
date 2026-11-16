# frozen_string_literal: true

require 'spec_helper'
require 'stringio'
require 'logger'
require 'woods'
require 'woods/console/server'
require 'woods/console/rack_middleware'
require 'woods/console/embedded_executor'

RSpec.describe 'Console diagnostic credential protection' do
  let(:secret) { 'fictional-opaque-credential-731628' }
  let(:replacement) { 'fictional-rotated-credential-835102' }
  let(:index) { Woods::Console::CredentialIndex.new(secrets: [secret]) }
  let(:stream) { StringIO.new }
  let(:logger) { Woods::Observability::StructuredLogger.new(output: stream) }

  before do
    stub_const('Woods::Console::Server::SCANNERS', Woods::Console::CredentialScannerRegistry.new)
    config = Woods::Configuration.new
    config.console_credential_defense_enabled = true
    allow(Woods).to receive(:configuration).and_return(config)
    allow(Woods::Console::Server).to receive(:build_credential_index).and_return(index)
  end

  def response_context
    Woods::Console::Server.send(:build_response_context, safe_ctx: nil, model_tables: {})
  end

  def rotate(value = replacement)
    fresh = Woods::Console::CredentialIndex.new(secrets: [value])
    allow(Woods::Console::CredentialIndex).to receive(:refresh).and_return(fresh)
    Woods::Console::Server.rebuild_credential_index(rails_app: Object.new)
  end

  # A rebuild replaces the index: the rotated-out value is no longer an
  # indexed credential, so only the current set is masked.
  def verify_replaced_index
    stream.truncate(0)
    stream.rewind
    yield(secret)
    expect(stream.string).to include(secret)
  end

  it 'scans unexpected dispatch failures and refreshes the same scanner' do
    message = secret
    pipeline = Woods::Console::DispatchPipeline.new(
      tool_name: 'console_count', handler: ->(_) { raise ArgumentError, message },
      properties: {}, conn_mgr: Object.new, ctx: response_context, logger: logger
    )
    response = pipeline.call({})
    expect(response.content.first[:text]).to eq('Internal error in console_count (details logged server-side)')
    expect(stream.string).not_to include(secret)
    expect(stream.string).to include('[REDACTED:credential]')

    rotate
    message = replacement
    pipeline.call({})
    expect(stream.string).not_to include(replacement)
    verify_replaced_index do |value|
      message = value
      pipeline.call({})
    end
  end

  it 'scans table-gate model, table and error fields before logging and after rotation' do
    message = secret
    context = response_context
    allow(context).to receive(:enforce!) { raise Woods::Console::TableGateError, message }
    pipeline = Woods::Console::DispatchPipeline.new(
      tool_name: 'console_count', handler: ->(_) { {} },
      properties: {}, conn_mgr: Object.new, ctx: context, logger: logger
    )
    [secret, replacement].each do |value|
      rotate if value == replacement
      message = value
      expect(pipeline.call(model: value, table: value)).to be_error
      expect(stream.string).not_to include(value)
      expect(stream.string).to include('[REDACTED:credential]')
    end
  end

  it 'scans unexpected serialization diagnostics before structured logging' do
    value = Object.new
    allow(value).to receive(:to_json).and_raise(ArgumentError, secret)
    executor = double(send_request: { 'ok' => true, 'result' => value })
    pipeline = Woods::Console::DispatchPipeline.new(
      tool_name: 'console_sample', handler: ->(_) { { tool: 'sample' } },
      properties: {}, conn_mgr: executor, ctx: response_context, logger: logger
    )
    expect(pipeline.call({})).to be_error
    expect(stream.string).not_to include(secret)
    expect(stream.string).to include('[REDACTED:credential]')
  end

  it 'omits an oversized diagnostic without logging a partial secret' do
    message = ('x' * 8190) + secret
    pipeline = Woods::Console::DispatchPipeline.new(
      tool_name: 'console_count', handler: ->(_) { raise ArgumentError, message },
      properties: {}, conn_mgr: Object.new, ctx: response_context, logger: logger
    )
    expect(pipeline.call({})).to be_error
    expect(stream.string.bytesize).to be < 1500
    expect(stream.string).to include('DIAGNOSTIC_OMITTED')
    expect(stream.string).not_to include(secret[0, 8])
  end

  it 'scans introspection failures at warn level and preserves other models' do
    bad = double('bad model', name: 'DiagnosticBadModel', abstract_class?: false)
    good = double('good model', name: 'DiagnosticGoodModel', abstract_class?: false,
                                table_exists?: true, column_names: ['id'], table_name: 'good_models',
                                reflect_on_all_associations: [])
    allow(bad).to receive(:table_exists?).and_raise(StandardError, secret)
    stub_const('ActiveRecord::Base', double('ActiveRecord Base'))
    allow(ActiveRecord::Base).to receive(:descendants).and_return([bad, good])
    middleware = Woods::Console::RackMiddleware.new(->(_) { [404, {}, []] })
    middleware.instance_variable_set(:@structured_logger, logger)

    result = middleware.send(:build_model_introspection)
    expect(result[:registry]).to eq('DiagnosticGoodModel' => ['id'])
    expect(stream.string).not_to include(secret)
    expect(JSON.parse(stream.string.lines.last).fetch('level')).to eq('warn')
    expect(stream.string).to include('[REDACTED:credential]')

    rotate
    allow(bad).to receive(:table_exists?).and_raise(StandardError, replacement)
    middleware.send(:build_model_introspection)
    expect(stream.string).not_to include(replacement)
    verify_replaced_index do |value|
      allow(bad).to receive(:table_exists?).and_raise(StandardError, value)
      middleware.send(:build_model_introspection)
    end
  end

  it 'scans the HTTP eager-load failure class before logging it' do
    name = 'FictionalOpaqueCredential731628'
    stub_const(name, Class.new(NameError))
    allow(Woods::Console::Server).to receive(:build_credential_index)
      .and_return(Woods::Console::CredentialIndex.new(secrets: [name]))
    application = double('application')
    allow(application).to receive(:eager_load!).and_raise(Object.const_get(name), 'fixture')
    stub_const('Rails', double('Rails', application: application))
    middleware = Woods::Console::RackMiddleware.new(->(_) { [404, {}, []] })
    middleware.instance_variable_set(:@structured_logger, logger)

    expect(middleware.send(:eager_load_application)).to be(false)
    expect(stream.string).to include('console.eager_load.failed', '[REDACTED:credential]')
    expect(stream.string).not_to include(name)
  end

  it 'gives the embedded executor an index-aware scanner that refreshes' do
    rails_logger = Logger.new(stream)
    stub_const('Rails', double('Rails'))
    allow(Rails).to receive(:logger).and_return(rails_logger)
    executor = nil
    allow(Woods::Console::EmbeddedExecutor).to receive(:new).and_wrap_original do |original, **options|
      executor = original.call(**options)
    end
    Woods::Console::Server.build_embedded(
      model_validator: Woods::Console::ModelValidator.new(registry: {}),
      safe_context: Woods::Console::SafeContext.new
    )
    executor.send(:log_execution_error, StandardError.new(secret))
    expect(stream.string).not_to include(secret)
    expect(stream.string).to include('[REDACTED:credential]')

    rotate
    executor.send(:log_execution_error, StandardError.new(replacement))
    expect(stream.string).not_to include(replacement)
    verify_replaced_index { |value| executor.send(:log_execution_error, StandardError.new(value)) }
  end
  it 'keeps timeout and logging-failure warnings free of exception messages' do
    stub_const('Rails', double('Rails', logger: Logger.new(stream)))
    context = Woods::Console::SafeContext.new
    context.send(:warn_timeout_unsupported, 'SQLite', StandardError.new(secret))
    expect(stream.string).not_to include(secret)
    expect(stream.string).to include('Queries will run without a per-statement time limit')

    server = Woods::Console::Server
    prior = server.instance_variable_get(:@observability_failure_reported)
    server.instance_variable_set(:@observability_failure_reported, false)
    expect { server.send(:handle_observability_failure, StandardError.new(secret)) }
      .to output(/structured logger failed \(StandardError\); further failures will be silent/).to_stderr
  ensure
    server&.instance_variable_set(:@observability_failure_reported, prior)
  end
  it 'keeps diagnostic pattern protection when a response pattern is disabled' do
    Woods.configuration.console_disabled_scanner_patterns = [:stripe_secret_key]
    credential = 'sk_test_abcdefghijklmnopqrstuvwxyz'
    value = Object.new
    allow(value).to receive(:to_json).and_raise(ArgumentError, credential)
    executor = double(send_request: { 'ok' => true, 'result' => value })
    allow(Woods::Console::EmbeddedExecutor).to receive(:new).and_return(executor)
    allow(Woods::Console::Server).to receive(:structured_logger).and_return(logger)
    server = Woods::Console::Server.build_embedded(
      model_validator: Woods::Console::ModelValidator.new(registry: {}),
      safe_context: Woods::Console::SafeContext.new
    )
    response = server.handle_json(JSON.generate(
                                    jsonrpc: '2.0', id: 1, method: 'tools/call',
                                    params: { name: 'console_count', arguments: { model: 'Fixture' } }
                                  ))
    expect(JSON.parse(response).dig('result', 'isError')).to eq(true)
    expect(stream.string).to include('[REDACTED]')
    expect(stream.string).not_to include(credential)
  end
end
