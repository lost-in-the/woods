# frozen_string_literal: true

require 'spec_helper'
require 'stringio'
require 'woods/console/stdio_transport'

RSpec.describe Woods::Console::StdioTransport do
  let(:server) { MCP::Server.new(name: 'console-stdio-test', version: '1') }
  let(:protocol_output) { StringIO.new }
  let(:transport) { described_class.new(server, output: protocol_output) }

  it 'writes UTF-8 responses as individual frames without using application stdout' do
    message = { jsonrpc: '2.0', id: 1, result: "é\nsecond line" }
    transport

    expect { transport.send_response(message) }.not_to output.to_stdout
    expect(protocol_output.string.lines.size).to eq(1)
    expect(JSON.parse(protocol_output.string)).to eq(JSON.parse(JSON.generate(message)))
    expect(protocol_output.external_encoding).to eq(Encoding::UTF_8)
  end

  it 'preserves already encoded SDK error responses' do
    message = JSON.generate(jsonrpc: '2.0', id: nil, error: { code: -32_700, message: 'Parse error' })

    transport.send_response(message)

    expect(protocol_output.string).to eq("#{message}\n")
  end

  it 'inherits the Index transport frame guard and writes the rejection to the protocol pipe' do
    expect(described_class.superclass).to eq(Woods::MCP::StdioTransport)

    broken = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\",\"x\":\"caf\xE9\"}\n".dup.force_encoding(Encoding::UTF_8)
    input = StringIO.new("#{broken}{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"ping\"}\n")
    application_stdout = StringIO.new
    original_in = $stdin
    original_out = $stdout
    $stdin = input
    $stdout = application_stdout
    begin
      expect { described_class.new(server, output: protocol_output).open }.to output(/rejected frame/).to_stderr
    ensure
      $stdin = original_in
      $stdout = original_out
    end
    expect(application_stdout.string).to eq('')

    responses = protocol_output.string.lines.map { |line| JSON.parse(line) }
    expect(responses.size).to eq(2)
    expect(responses[0]['error']).to include('code' => -32_700)
    expect(responses[1]).to include('id' => 2, 'result' => {})
  end

  it 'routes inherited notifications through the dedicated protocol writer' do
    expect(transport.send_notification('notifications/tools/list_changed')).to be(true)
    expect(JSON.parse(protocol_output.string)).to eq(
      'jsonrpc' => '2.0', 'method' => 'notifications/tools/list_changed'
    )
  end
end
