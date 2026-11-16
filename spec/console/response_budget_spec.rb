# frozen_string_literal: true

require 'spec_helper'
require 'mcp'
require 'woods'
require 'woods/console/connection_manager'
require 'woods/console/sql_validator'
require 'woods/console/eval_guard'
require 'woods/console/dispatch_pipeline'
require 'woods/console/safe_context'
require 'woods/console/table_gate'

RSpec.describe 'Console response budgets' do
  def dispatch(result, renderer: nil, ctx: Woods::Console::NullResponseContext.instance)
    conn = double('executor', send_request: { 'ok' => true, 'result' => result })
    Woods::Console::DispatchPipeline.new(tool_name: 'console_sample', handler: ->(_) { {} },
                                         properties: {}, conn_mgr: conn, renderer: renderer, ctx: ctx).call({})
  end

  def text_of(response)
    response.content.first[:text]
  end

  it 'omits an oversized value completely before rendering' do
    response = dispatch({ 'records' => [{ 'body' => 'fictional-value-' * 5000 }] })
    expect(response).not_to be_error
    expect(text_of(response)).to include('value_omitted', 'max_value_bytes')
    expect(text_of(response)).not_to include('fictional-value')
  end

  it 'refuses a large collection of individually small values' do
    response = dispatch({ 'rows' => Array.new(5000) { ['x' * 1000] } })
    expect(response).to be_error
    expect(text_of(response)).to include('response_budget_exceeded')
    expect(text_of(response)).not_to include('x' * 10)
  end

  it 'labels the refusal with a stable error code' do
    response = dispatch({ 'rows' => Array.new(5000) { ['x' * 1000] } })
    expect(response.to_h.dig(:_meta, :error_code)).to eq('response_budget_exceeded')
  end

  it 'counts final escaping and renderer output in the encoded tool result' do
    renderer = double('renderer', render_default: "\u0001" * 800_000)
    response = dispatch({ 'count' => 1 }, renderer: renderer)
    expect(response).to be_error
    expect(text_of(response)).to include('response_budget_exceeded')
    expect(JSON.generate(response.to_h).bytesize).to be < 1024
  end

  it 'refuses oversized keys instead of changing field identity' do
    response = dispatch({ 'z' * 70_000 => 'ordinary' })
    expect(response).to be_error
    expect(text_of(response)).not_to include('z' * 10)
  end

  it 'leaves ordinary results unchanged' do
    response = dispatch({ 'record' => { 'id' => 1, 'name' => 'Ada' } })
    expect(JSON.parse(text_of(response))).to eq('record' => { 'id' => 1, 'name' => 'Ada' })
  end

  it 'refuses oversized SQL headers without renaming their identity' do
    response = dispatch({ 'columns' => ['a' * 70_000], 'rows' => [['value']] })
    expect(response).to be_error
    expect(text_of(response)).not_to include('a' * 10)
  end

  it 'uses bytes rather than characters for multibyte values' do
    response = dispatch({ 'value' => 'é' * 40_000 })
    expect(text_of(response)).to include('value_omitted')
    expect(text_of(response)).not_to include('é')
  end

  it 'caps custom serializer output before credential scanning' do
    object = Object.new
    def object.to_json(*)
      JSON.generate('body' => 'x' * (5 * 1024 * 1024))
    end
    response = dispatch({ 'record' => object })
    expect(response).to be_error
    expect(text_of(response)).to include('response_budget_exceeded')
  end

  it 'redacts protected values before their serializer can execute' do
    protected = Object.new
    def protected.to_json(*)
      raise 'must never execute'
    end
    safe = Woods::Console::SafeContext.new(redacted_columns: ['password'])
    ctx = Woods::Console::ResponseContext.build(safe_ctx: safe)
    response = dispatch({ 'record' => { 'password' => protected, 'body' => 'x' * 70_000 } }, ctx: ctx)
    expect(response).not_to be_error
    expect(text_of(response)).to include('[REDACTED]', 'value_omitted')
  end

  it 'refuses deeply nested results without overflowing the stack' do
    result = 'leaf'
    110.times { result = [result] }
    response = dispatch(result)
    expect(response).to be_error
    expect(text_of(response)).to include('response_budget_exceeded')
  end

  it 'validates both byte limits before constructing a serving pipeline' do
    %i[console_max_value_bytes console_max_response_bytes].each do |name|
      [0, -1, nil, '1000', 1.5].each do |value|
        config = Woods::Configuration.new
        config.public_send("#{name}=", value)
        expect { Woods::Console::ResponseBudget.new(config: config) }.to raise_error(ArgumentError, /#{name}/)
      end
    end
  end

  it 'honors custom byte budgets including the exact string boundary' do
    config = Woods::Configuration.new
    config.console_max_value_bytes = 12
    config.console_max_response_bytes = 256
    budget = Woods::Console::ResponseBudget.new(config: config)
    expect(budget.apply('a' * 12)).to eq('a' * 12)
    expect(budget.apply('a' * 13)).to include('type' => 'value_omitted', 'limit_bytes' => 12)
    expect { budget.check_encoded!('a' * 256) }.not_to raise_error
    expect { budget.check_encoded!('a' * 257) }.to raise_error(Woods::Console::ResponseBudget::Exceeded)
  end

  it 'enforces the shipped 65536-byte boundary without truncating a protected value' do
    budget = Woods::Console::ResponseBudget.new(config: Woods::Configuration.new)
    expect(budget.apply('x' * 65_536)).to eq('x' * 65_536)
    expect(budget.apply('x' * 65_537)).to include('type' => 'value_omitted')
    context = Woods::Console::SafeContext.new(redacted_columns: ['password'])
    response = dispatch({ 'record' => { 'password' => 'x' * 65_537 } },
                        ctx: Woods::Console::ResponseContext.build(safe_ctx: context))
    expect(text_of(response)).to include('[REDACTED]')
    expect(text_of(response)).not_to include('value_omitted')
  end

  it 'refuses a cycle before calling a redactor' do
    ctx = double('context', enforce!: nil, credential_scanner: nil)
    expect(ctx).not_to receive(:redact)
    cycle = []
    cycle << cycle
    response = dispatch(cycle, ctx: ctx)
    expect(response).to be_error
    expect(text_of(response)).to include('response_budget_exceeded')
  end

  it 'reserves the modern SDK discriminator inside the final response cap' do
    text = 'ordinary rendered result'
    config = Woods::Configuration.new
    encoded = MCP::Tool::Response.new([{ type: 'text', text: text }]).to_h.merge(resultType: 'complete')
    config.console_max_response_bytes = JSON.generate(encoded).bytesize - 1
    allow(Woods).to receive(:configuration).and_return(config)
    response = dispatch({ 'count' => 1 }, renderer: double('renderer', render_default: text))
    expect(response).to be_error
    expect(text_of(response)).to include('response_budget_exceeded')
  end

  it 'bounds an executor refusal the same way as a result' do
    config = Woods::Configuration.new
    config.console_max_response_bytes = 512
    allow(Woods).to receive(:configuration).and_return(config)
    conn = double('executor', send_request: { 'ok' => false, 'error_type' => 'validation',
                                              'error' => 'fictional-refusal ' * 100 })
    response = Woods::Console::DispatchPipeline.new(tool_name: 'console_sample', handler: ->(_) { {} },
                                                    properties: {}, conn_mgr: conn).call({})
    expect(response).to be_error
    expect(text_of(response)).to include('response_budget_exceeded')
    expect(text_of(response)).not_to include('fictional-refusal')
  end
end
