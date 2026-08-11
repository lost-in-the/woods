# frozen_string_literal: true

require 'spec_helper'
require 'json'
require 'mcp'
require 'woods/mcp/tasks/request_capture'

RSpec.describe Woods::MCP::Tasks::RequestCapture do
  let(:server) do
    srv = MCP::Server.new(name: 'test', version: '1.0')
    srv.singleton_class.prepend(described_class)
    srv
  end

  # The tool block only receives `arguments`, never the surrounding params, so
  # the opt-in flag has to be stashed where the handler can reach it.
  def define_probe(srv)
    seen = []
    srv.define_tool(name: 'probe', description: 'probe', input_schema: { type: 'object', properties: {} }) do |**|
      seen << Woods::MCP::Tasks::RequestCapture.tasks_requested?
      MCP::Tool::Response.new([{ type: 'text', text: 'ok' }])
    end
    seen
  end

  def call(srv, params)
    srv.handle_json(JSON.generate({ jsonrpc: '2.0', id: 1, method: 'tools/call', params: params }))
  end

  let(:opted_in_meta) do
    { '_meta' => { 'io.modelcontextprotocol/clientCapabilities' =>
      { 'extensions' => { 'io.modelcontextprotocol/tasks' => {} } } } }
  end

  it 'exposes the opt-in to the tool handler' do
    seen = define_probe(server)
    call(server, { 'name' => 'probe', 'arguments' => {} }.merge(opted_in_meta))
    expect(seen).to eq([true])
  end

  it 'reports no opt-in for a client that did not declare the extension' do
    seen = define_probe(server)
    call(server, { 'name' => 'probe', 'arguments' => {} })
    expect(seen).to eq([false])
  end

  it 'is false outside of any request' do
    expect(described_class.tasks_requested?).to be false
  end

  # Puma reuses request threads, so a leaked flag would make the *next* tool
  # call on that thread believe a client had opted in when it had not — and
  # hand a task to a client that cannot poll it.
  it 'clears the flag after the request completes' do
    define_probe(server)
    call(server, { 'name' => 'probe', 'arguments' => {} }.merge(opted_in_meta))
    expect(described_class.tasks_requested?).to be false
  end

  it 'clears the flag even when the tool raises' do
    server.define_tool(name: 'boom', description: 'boom', input_schema: { type: 'object', properties: {} }) do |**|
      raise 'kaboom'
    end
    call(server, { 'name' => 'boom', 'arguments' => {} }.merge(opted_in_meta))
    expect(described_class.tasks_requested?).to be false
  end

  it 'does not leak across sequential calls on one thread' do
    seen = define_probe(server)
    call(server, { 'name' => 'probe', 'arguments' => {} }.merge(opted_in_meta))
    call(server, { 'name' => 'probe', 'arguments' => {} })
    expect(seen).to eq([true, false])
  end

  it 'keeps concurrent requests on separate threads independent' do
    seen = Queue.new
    server.define_tool(name: 'slow', description: 'slow', input_schema: { type: 'object', properties: {} }) do |**|
      sleep 0.01
      seen << Woods::MCP::Tasks::RequestCapture.tasks_requested?
      MCP::Tool::Response.new([{ type: 'text', text: 'ok' }])
    end

    threads = [
      Thread.new { call(server, { 'name' => 'slow', 'arguments' => {} }.merge(opted_in_meta)) },
      Thread.new { call(server, { 'name' => 'slow', 'arguments' => {} }) }
    ]
    threads.each(&:join)

    expect([seen.pop, seen.pop].sort_by(&:to_s)).to eq([false, true])
  end

  it 'still returns the tool result unchanged' do
    define_probe(server)
    raw = call(server, { 'name' => 'probe', 'arguments' => {} })
    expect(JSON.parse(raw).dig('result', 'content', 0, 'text')).to eq('ok')
  end
end
