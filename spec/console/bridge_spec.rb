# frozen_string_literal: true

require 'spec_helper'
require 'codebase_index/console/bridge'

RSpec.describe CodebaseIndex::Console::Bridge do
  let(:registry) do
    {
      'User' => %w[id email name created_at],
      'Post' => %w[id title body user_id]
    }
  end
  let(:validator) { CodebaseIndex::Console::ModelValidator.new(registry: registry) }
  let(:connection) { instance_double('Connection') }
  let(:safe_context) { CodebaseIndex::Console::SafeContext.new(connection: connection) }
  let(:input) { StringIO.new }
  let(:output) { StringIO.new }

  subject(:bridge) do
    described_class.new(input: input, output: output, model_validator: validator, safe_context: safe_context)
  end

  before do
    allow(connection).to receive(:transaction).and_yield
    allow(connection).to receive(:execute)
  end

  describe '#handle_request' do
    it 'returns success for status tool' do
      request = { 'id' => 'r1', 'tool' => 'status', 'params' => {} }
      response = bridge.handle_request(request)

      expect(response['id']).to eq('r1')
      expect(response['ok']).to be true
      expect(response['result']['status']).to eq('ok')
      expect(response['result']['models']).to eq(%w[Post User])
      expect(response['timing_ms']).to be_a(Numeric)
    end

    it 'returns success for count tool' do
      request = { 'id' => 'r2', 'tool' => 'count', 'params' => { 'model' => 'User' } }
      response = bridge.handle_request(request)

      expect(response['ok']).to be true
      expect(response['result']).to include('count')
    end

    it 'returns success for schema tool' do
      request = { 'id' => 'r3', 'tool' => 'schema', 'params' => { 'model' => 'User' } }
      response = bridge.handle_request(request)

      expect(response['ok']).to be true
      expect(response['result']['columns']).to include('email')
    end

    it 'returns error for unknown tool' do
      request = { 'id' => 'r4', 'tool' => 'drop_table', 'params' => {} }
      response = bridge.handle_request(request)

      expect(response['ok']).to be false
      expect(response['error']).to match(/Unknown tool/)
      expect(response['error_type']).to eq('unknown_tool')
    end

    it 'returns validation error for unknown model' do
      request = { 'id' => 'r5', 'tool' => 'count', 'params' => { 'model' => 'Hacker' } }
      response = bridge.handle_request(request)

      expect(response['ok']).to be false
      expect(response['error']).to match(/Unknown model: Hacker/)
      expect(response['error_type']).to eq('validation')
    end

    it 'returns validation error for missing model param' do
      request = { 'id' => 'r6', 'tool' => 'count', 'params' => {} }
      response = bridge.handle_request(request)

      expect(response['ok']).to be false
      expect(response['error']).to match(/Missing required parameter: model/)
    end

    it 'validates columns in pluck tool' do
      request = { 'id' => 'r7', 'tool' => 'pluck',
                  'params' => { 'model' => 'User', 'columns' => %w[email bad_col] } }
      response = bridge.handle_request(request)

      expect(response['ok']).to be false
      expect(response['error']).to match(/Unknown column 'bad_col'/)
    end

    it 'validates column in aggregate tool' do
      request = { 'id' => 'r8', 'tool' => 'aggregate',
                  'params' => { 'model' => 'User', 'column' => 'nonexistent', 'function' => 'sum' } }
      response = bridge.handle_request(request)

      expect(response['ok']).to be false
      expect(response['error']).to match(/Unknown column 'nonexistent'/)
    end

    it 'returns success for sample tool' do
      request = { 'id' => 'r9', 'tool' => 'sample', 'params' => { 'model' => 'User' } }
      response = bridge.handle_request(request)

      expect(response['ok']).to be true
      expect(response['result']).to include('records')
    end

    it 'returns success for find tool' do
      request = { 'id' => 'r10', 'tool' => 'find', 'params' => { 'model' => 'User', 'id' => 1 } }
      response = bridge.handle_request(request)

      expect(response['ok']).to be true
      expect(response['result']).to include('record')
    end

    it 'returns success for recent tool' do
      request = { 'id' => 'r11', 'tool' => 'recent', 'params' => { 'model' => 'Post' } }
      response = bridge.handle_request(request)

      expect(response['ok']).to be true
      expect(response['result']).to include('records')
    end

    it 'returns success for association_count tool' do
      request = { 'id' => 'r12', 'tool' => 'association_count',
                  'params' => { 'model' => 'User', 'id' => 1, 'association' => 'posts' } }
      response = bridge.handle_request(request)

      expect(response['ok']).to be true
      expect(response['result']).to include('count')
    end
  end

  describe 'dispatch security' do
    it 'rejects a tool name not in SUPPORTED_TOOLS even if a matching private method exists' do
      # 'parse_request' is a private method — a crafted tool name must not reach it
      request = { 'id' => 'sec1', 'tool' => 'parse_request', 'params' => { 'model' => 'User' } }
      response = bridge.handle_request(request)

      expect(response['ok']).to be false
      expect(response['error_type']).to eq('unknown_tool')
    end

    it 'rejects a tool name that would call a private helper via handle_ prefix' do
      # 'validate_model_param' is private; a tool named 'validate_model_param' must not succeed
      request = { 'id' => 'sec2', 'tool' => 'validate_model_param', 'params' => { 'model' => 'User' } }
      response = bridge.handle_request(request)

      expect(response['ok']).to be false
      expect(response['error_type']).to eq('unknown_tool')
    end

    it 'TOOL_HANDLERS covers every SUPPORTED_TOOLS entry' do
      described_class::SUPPORTED_TOOLS.each do |tool|
        expect(described_class::TOOL_HANDLERS).to have_key(tool)
      end
    end

    it 'TOOL_HANDLERS maps each tool to its handle_ method symbol' do
      described_class::SUPPORTED_TOOLS.each do |tool|
        expect(described_class::TOOL_HANDLERS[tool]).to eq(:"handle_#{tool}")
      end
    end
  end

  describe '#run' do
    it 'processes multiple JSON-lines requests' do
      requests = [
        { id: 'a', tool: 'status', params: {} },
        { id: 'b', tool: 'count', params: { model: 'User' } }
      ]
      input_io = StringIO.new("#{requests.map { |r| JSON.generate(r) }.join("\n")}\n")
      output_io = StringIO.new

      b = described_class.new(input: input_io, output: output_io,
                              model_validator: validator, safe_context: safe_context)
      b.run

      output_io.rewind
      lines = output_io.readlines.map { |l| JSON.parse(l) }
      expect(lines.size).to eq(2)
      expect(lines[0]['id']).to eq('a')
      expect(lines[1]['id']).to eq('b')
    end

    it 'handles invalid JSON gracefully' do
      input_io = StringIO.new("not valid json\n")
      output_io = StringIO.new

      b = described_class.new(input: input_io, output: output_io,
                              model_validator: validator, safe_context: safe_context)
      b.run

      output_io.rewind
      response = JSON.parse(output_io.readlines.first)
      expect(response['ok']).to be false
      expect(response['error_type']).to eq('parse')
    end

    it 'skips blank lines' do
      input_io = StringIO.new("\n  \n")
      output_io = StringIO.new

      b = described_class.new(input: input_io, output: output_io,
                              model_validator: validator, safe_context: safe_context)
      b.run

      output_io.rewind
      expect(output_io.readlines).to be_empty
    end
  end
end
