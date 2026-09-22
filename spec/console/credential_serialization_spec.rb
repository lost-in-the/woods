# frozen_string_literal: true

require 'spec_helper'
require 'mcp'
require 'woods/console/dispatch_pipeline'
require 'woods/console/credential_scanner'
require 'woods/console/safe_context'
require 'woods/console/console_response_renderer'

RSpec.describe 'Console credential serialization boundary' do
  let(:secret) { "ghp_#{'a' * 36}" }
  let(:index_secret) { 'indexed "secret" with escape' }
  let(:scanner) do
    Woods::Console::CredentialScanner.new(
      secret_index: Woods::Console::CredentialIndex.new(secrets: [index_secret])
    )
  end

  def response_for(data, renderer, safe_context: nil)
    connection = double('connection', send_request: { 'ok' => true, 'result' => data })
    context = Woods::Console::ResponseContext.build(credential_scanner: scanner, safe_ctx: safe_context)
    pipeline = Woods::Console::DispatchPipeline.new(
      tool_name: 'console_sample', handler: ->(_) { { tool: 'sample' } }, integer_keys: [],
      conn_mgr: connection, ctx: context, renderer: renderer
    )
    pipeline.call({})
  end

  def response_text(data, renderer, safe_context: nil)
    response = response_for(data, renderer, safe_context: safe_context)
    expect(response).not_to be_error
    response.content.first.fetch(:text)
  end

  [Woods::Console::JsonConsoleRenderer, Woods::Console::ConsoleResponseRenderer].each do |renderer_class|
    it "refuses a failing serializer safely through #{renderer_class}" do
      value = Object.new
      value.define_singleton_method(:to_json) { |*_args| raise 'private serialization detail' }
      response = response_for({ 'record' => value }, renderer_class.new)
      expect(response).to be_error
      text = response.content.first.fetch(:text)
      expect(text).to include('could not be serialized safely')
      expect(text).not_to include('private serialization detail')
    end

    it "refuses invalid serializer JSON safely through #{renderer_class}" do
      value = Object.new
      value.define_singleton_method(:to_json) { |*_args| 'private invalid JSON detail' }
      response = response_for({ 'record' => value }, renderer_class.new)
      expect(response).to be_error
      text = response.content.first.fetch(:text)
      expect(text).to include('could not be serialized safely')
      expect(text).not_to include('private invalid JSON detail')
    end

    it "refuses a failing #{renderer_class} without its exception details" do
      renderer = renderer_class.new
      allow(renderer).to receive(:render_default).and_raise(RuntimeError, 'private renderer detail')
      response = response_for({ 'record' => { 'safe' => 'ready' } }, renderer)
      expect(response).to be_error
      text = response.content.first.fetch(:text)
      expect(text).to include('could not be serialized safely')
      expect(text).not_to include('private renderer detail')
    end

    it "scans Symbol values before #{renderer_class} emits them" do
      text = response_text({ 'record' => { 'nested' => [secret.to_sym], 'safe' => :ready } }, renderer_class.new)
      expect(text).not_to include(secret)
      expect(text).to include('[REDACTED]', 'ready')
    end

    it "scans custom JSON values and stringified keys before #{renderer_class} emits them" do
      value = Object.new
      escaped_secret = index_secret
      value.define_singleton_method(:to_json) { |*_args| JSON.generate(escaped_secret) }
      value.define_singleton_method(:to_s) { escaped_secret }
      key = Object.new
      token = secret
      key.define_singleton_method(:to_s) { token }
      text = response_text({ 'record' => { key => value } }, renderer_class.new)
      expect(text).not_to include(secret, index_secret, 'indexed', 'with escape')
      expect(text).to include('[REDACTED]')
    end
  end

  it 'redacts protected values before invoking any custom serializer' do
    calls = 0
    protected_value = Object.new
    protected_value.define_singleton_method(:to_json) do |*_args|
      calls += 1
      raise 'protected serializer must not run'
    end
    policy = Woods::Console::SafeContext.new(redacted_columns: ['protected'])
    text = response_text({ 'record' => { 'protected' => protected_value, 'safe' => 'ready' } },
                         Woods::Console::JsonConsoleRenderer.new, safe_context: policy)
    expect(calls).to eq(0)
    expect(text).to include('[REDACTED]', 'ready')
  end

  it 'redacts protected fields introduced by a custom serializer too' do
    value = Object.new
    value.define_singleton_method(:to_json) { |*_args| JSON.generate('protected' => 'hidden-value', 'safe' => 'ready') }
    policy = Woods::Console::SafeContext.new(redacted_columns: ['protected'])
    text = response_text({ 'record' => value }, Woods::Console::JsonConsoleRenderer.new, safe_context: policy)
    expect(text).not_to include('hidden-value')
    expect(text).to include('[REDACTED]', 'ready')
  end

  it 'retains JSON primitives and scans symbol values through the direct scanner too' do
    value, counts = scanner.scan([secret.to_sym, :ready, 3, 1.5, true, false, nil])
    expect(value).to eq([:'[REDACTED]', :ready, 3, 1.5, true, false, nil])
    expect(counts).to eq(github_token: 1)
  end
end
