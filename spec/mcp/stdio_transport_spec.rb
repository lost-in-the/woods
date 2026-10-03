# frozen_string_literal: true

require 'spec_helper'
require 'stringio'
require 'woods/mcp/stdio_transport'

RSpec.describe Woods::MCP::StdioTransport do
  let(:server) do
    MCP::Server.new(name: 'frame-guard-test', version: '1').tap do |s|
      schema = { type: 'object', properties: { text: { type: 'string' } } }
      s.define_tool(name: 'echo', description: 'echo', input_schema: schema) do |text:, server_context: nil|
        _ = server_context
        MCP::Tool::Response.new([{ type: 'text', text: text }])
      end
    end
  end

  # Runs the transport loop in-process over the given stdin bytes. The SDK
  # reads $stdin and writes $stdout, tagging both UTF-8 at construction, so
  # the globals are swapped before the transport is built and restored after.
  def serve(frames)
    input = StringIO.new(frames.join)
    output = StringIO.new
    original_in = $stdin
    original_out = $stdout
    $stdin = input
    $stdout = output
    begin
      described_class.new(server).open
    ensure
      $stdin = original_in
      $stdout = original_out
    end
    output.string.lines.map { |line| JSON.parse(line) }
  end

  def ping(id)
    "#{JSON.generate(jsonrpc: '2.0', id: id, method: 'ping')}\n"
  end

  def echo_call(id, text)
    "#{JSON.generate(jsonrpc: '2.0', id: id, method: 'tools/call',
                     params: { name: 'echo', arguments: { text: text } })}\n"
  end

  it 'attaches to the SDK hook it overrides' do
    expect(described_class.superclass.private_method_defined?(:read_line)).to be(true)
  end

  it 'answers a frame that is not valid UTF-8 with a parse error and keeps serving (N-mcp-1)' do
    broken = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\",\"x\":\"caf\xE9\"}\n".dup.force_encoding(Encoding::UTF_8)
    expect(broken.valid_encoding?).to be(false)

    responses = nil
    expect { responses = serve([broken, ping(2)]) }.to output(/rejected frame/).to_stderr

    expect(responses.size).to eq(2)
    expect(responses[0]).to eq('jsonrpc' => '2.0', 'id' => nil,
                               'error' => { 'code' => -32_700, 'message' => 'Parse error: frame is not valid UTF-8' })
    expect(responses[1]).to include('id' => 2, 'result' => {})
  end

  it 'answers a frame whose escapes decode to invalid UTF-8 with a parse error and keeps serving (N-cs-3)' do
    lone_surrogate = %({"jsonrpc":"2.0","id":1,"method":"ping","params":{"col\\udc00name":1}}\n)

    responses = nil
    expect { responses = serve([lone_surrogate, ping(2)]) }.to output(/rejected frame/).to_stderr

    expect(responses.size).to eq(2)
    expect(responses[0]['error']).to include('code' => -32_700)
    expect(responses[0]['error']['message']).to include('Parse error', 'invalid UTF-8')
    expect(responses[1]).to include('id' => 2, 'result' => {})
  end

  it 'passes valid frames through unchanged, multibyte text included' do
    responses = serve([echo_call(1, 'café ✓'), ping(2)])

    expect(responses.size).to eq(2)
    expect(responses[0].dig('result', 'content', 0, 'text')).to eq('café ✓')
    expect(responses[1]).to include('id' => 2, 'result' => {})
  end

  it 'leaves an ordinary parse error to the SDK, which answers it once' do
    responses = serve(["{not json\n", ping(2)])

    expect(responses.size).to eq(2)
    expect(responses[0]['error']).to include('code' => -32_700)
    expect(responses[1]).to include('id' => 2, 'result' => {})
  end
end
