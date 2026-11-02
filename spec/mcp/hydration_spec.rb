# frozen_string_literal: true

require 'spec_helper'
require 'json'
require 'mcp'
require 'woods'
require 'woods/dependency_graph'
require 'woods/mcp/server'
require 'woods/mcp/published_lexical_retriever'
require 'woods/mcp/stdio_transport'

# Startup ordering of the Index MCP server (WDS-78): the `initialize`
# handshake is answered before the cache warm-up, which runs on a background
# thread once the handshake response is on the wire. A tool call that arrives
# during the warm-up waits for it (bounded) and answers correctly either way.
RSpec.describe Woods::MCP::Hydration do
  let(:fixture_dir) { File.expand_path('../fixtures/woods', __dir__) }

  # A latch the stubbed warm-up blocks on until the example releases it.
  let(:latch) { Queue.new }

  def hold_warmup!
    allow_any_instance_of(Woods::MCP::IndexReader).to receive(:warmup!).and_wrap_original do |original, *args|
      latch.pop
      original.call(*args)
    end
  end

  def build(**options)
    Woods::MCP::Server.build(index_dir: fixture_dir, response_format: :json, **options)
  end

  def rpc(server, method, params = {}, id: 1)
    raw = server.handle_json(JSON.generate({ jsonrpc: '2.0', id: id, method: method, params: params }))
    raw && JSON.parse(raw)
  end

  def initialize_request(server)
    rpc(server, 'initialize', { 'protocolVersion' => '2025-06-18', 'capabilities' => {},
                                'clientInfo' => { 'name' => 'spec-client', 'version' => '1.0' } })
  end

  def tool_call(server, name, arguments = {}, id: 2)
    rpc(server, 'tools/call', { 'name' => name, 'arguments' => arguments }, id: id)
  end

  def tool_json(response)
    JSON.parse(response.dig('result', 'content', 0, 'text'))
  end

  def wait_until(seconds: 5)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
    until yield
      raise 'condition not met in time' if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.01
    end
  end

  after { latch.close }

  describe 'answer-first startup (the default)' do
    it 'answers initialize before the warm-up has run, then warms on a background thread' do
      hold_warmup!
      server = build
      hydration = server.woods_hydration
      expect(hydration.state).to eq(:pending)

      response = initialize_request(server)

      expect(response.dig('result', 'serverInfo', 'name')).to eq('woods')
      expect(hydration.state).to eq(:warming)

      latch << :go
      wait_until { hydration.done? }
      expect(hydration.state).to eq(:ready)
      expect(hydration.to_h).to include(state: 'ready', warmup: 'after_handshake', error: nil)
      expect(hydration.to_h[:duration_seconds]).to be_a(Numeric)
    end

    it 'does not start the warm-up at build time' do
      expect_any_instance_of(Woods::MCP::IndexReader).not_to receive(:warmup!)
      server = build
      expect(server.woods_hydration.state).to eq(:pending)
    end

    it 'answers a tool call made during the warm-up with the correct result once the warm-up finishes' do
      hold_warmup!
      server = build
      initialize_request(server)
      expect(server.woods_hydration.state).to eq(:warming)

      call = Thread.new { tool_call(server, 'lookup', { 'identifier' => 'Post' }) }
      sleep 0.1
      expect(call.alive?).to be(true), 'the call should wait for the warm-up'
      expect(server.woods_hydration.state).to eq(:warming)

      latch << :go
      response = call.value
      expect(server.woods_hydration.state).to eq(:ready)
      expect(tool_json(response)['identifier']).to eq('Post')
    end

    it 'answers from the cold reader when the warm-up outlasts the wait cap, and never errors' do
      hold_warmup!
      server = build
      hydration = server.woods_hydration
      allow(hydration).to receive(:wait_cap).and_return(0.2)
      initialize_request(server)

      response = tool_call(server, 'lookup', { 'identifier' => 'Post' })

      expect(hydration.state).to eq(:warming)
      expect(response).not_to have_key('error')
      expect(tool_json(response)['identifier']).to eq('Post')
      latch << :go
      wait_until { hydration.done? }
    end

    it 'starts the warm-up on the first tool call when no handshake preceded it' do
      hold_warmup!
      server = build
      hydration = server.woods_hydration
      allow(hydration).to receive(:wait_cap).and_return(0.2)

      response = tool_call(server, 'lookup', { 'identifier' => 'Post' })

      expect(hydration.state).to eq(:warming)
      expect(tool_json(response)['identifier']).to eq('Post')
      latch << :go
      wait_until { hydration.done? }
    end
  end

  describe 'woods_status' do
    it 'reports hydration warming, then ready, next to the unchanged bootstrap report' do
      hold_warmup!
      server = build
      initialize_request(server)

      warming = tool_json(tool_call(server, 'woods_status'))
      expect(warming['hydration']).to include('state' => 'warming', 'warmup' => 'after_handshake', 'error' => nil)
      expect(warming['hydration']['started_at']).to be_a(String)
      expect(warming).to have_key('bootstrap')

      latch << :go
      wait_until { server.woods_hydration.done? }

      ready = tool_json(tool_call(server, 'woods_status', {}, id: 3))
      expect(ready['hydration']).to include('state' => 'ready', 'error' => nil)
      expect(ready['hydration']['finished_at']).to be_a(String)
      expect(ready['hydration']['duration_seconds']).to be_a(Numeric)
    end

    it 'answers during the warm-up without waiting for it' do
      hold_warmup!
      server = build
      initialize_request(server)

      status = Timeout.timeout(5) { tool_json(tool_call(server, 'woods_status')) }
      expect(status['hydration']['state']).to eq('warming')
      latch << :go
      wait_until { server.woods_hydration.done? }
    end
  end

  describe 'a warm-up that raises' do
    it 'is captured into hydration failed with the message, and the server keeps serving' do
      allow_any_instance_of(Woods::MCP::IndexReader).to receive(:warmup!).and_raise(IOError, 'disk went away')
      server = build
      initialize_request(server)
      wait_until { server.woods_hydration.done? }

      status = tool_json(tool_call(server, 'woods_status'))
      expect(status['hydration']).to include(
        'state' => 'failed', 'error' => { 'class' => 'IOError', 'message' => 'disk went away' }
      )

      response = tool_call(server, 'lookup', { 'identifier' => 'Post' }, id: 3)
      expect(response).not_to have_key('error')
      expect(tool_json(response)['identifier']).to eq('Post')
    end
  end

  describe 'warmup: :before_handshake' do
    it 'warms synchronously inside build, before any handshake' do
      expect_any_instance_of(Woods::MCP::IndexReader).to receive(:warmup!).once.and_call_original
      server = build(warmup: :before_handshake)

      expect(server.woods_hydration.state).to eq(:ready)
      expect(server.woods_hydration.to_h).to include(state: 'ready', warmup: 'before_handshake')
      expect(initialize_request(server).dig('result', 'serverInfo', 'name')).to eq('woods')
      expect(tool_json(tool_call(server, 'woods_status'))['hydration']['state']).to eq('ready')
    end

    it 'lets a warm-up exception propagate out of build, as it always did' do
      allow_any_instance_of(Woods::MCP::IndexReader).to receive(:warmup!).and_raise(IOError, 'disk went away')
      expect { build(warmup: :before_handshake) }.to raise_error(IOError, 'disk went away')
    end
  end

  describe 'warmup: false' do
    it 'never warms and reports ready with warmup none' do
      expect_any_instance_of(Woods::MCP::IndexReader).not_to receive(:warmup!)
      server = build(warmup: false)
      initialize_request(server)
      status = tool_json(tool_call(server, 'woods_status'))
      expect(status['hydration']).to include('state' => 'ready', 'warmup' => 'none')
    end
  end

  it 'rejects an unknown warmup: value' do
    expect { build(warmup: :later) }.to raise_error(ArgumentError, /warmup: must be/)
  end

  describe 'the lexical retriever' do
    it 'is warmed on the same background thread, after the reader' do
      retriever = instance_double(Woods::MCP::PublishedLexicalRetriever, mode: :lexical)
      order = Queue.new
      allow(retriever).to receive(:bind_reader)
      allow(retriever).to receive(:warmup!) { order << :retriever }
      allow_any_instance_of(Woods::MCP::IndexReader).to receive(:warmup!) { order << :reader }
      server = build(retriever: retriever)
      expect(retriever).to have_received(:bind_reader)
      expect(order).to be_empty

      initialize_request(server)
      wait_until { server.woods_hydration.done? }
      expect(order.size.times.map { order.pop }).to eq(%i[reader retriever])
    end
  end

  describe Woods::MCP::StdioTransport do
    # Runs the transport loop over pipes on its own thread; the SDK reads
    # `$stdin` and writes `$stdout`, so the globals are swapped around it.
    def with_stdio_server(server)
      client_in, server_out = IO.pipe
      server_in, client_out = IO.pipe
      original_in = $stdin
      original_out = $stdout
      $stdin = server_in
      $stdout = server_out
      transport = described_class.new(server)
      loop_thread = Thread.new { transport.open }
      yield client_out, client_in
    ensure
      $stdin = original_in
      $stdout = original_out
      client_out&.close
      loop_thread&.join(5)
      [client_in, server_in, server_out].each { |io| io.close unless io.nil? || io.closed? }
    end

    it 'starts the warm-up only after the initialize response has been written' do
      hold_warmup!
      server = build
      hydration = server.woods_hydration

      with_stdio_server(server) do |to_server, from_server|
        expect(hydration.state).to eq(:pending)
        to_server.puts JSON.generate(jsonrpc: '2.0', id: 1, method: 'initialize',
                                     params: { protocolVersion: '2025-06-18', capabilities: {},
                                               clientInfo: { name: 'spec-client', version: '1.0' } })
        to_server.flush
        response = JSON.parse(from_server.gets)

        expect(response.dig('result', 'serverInfo', 'name')).to eq('woods')
        wait_until { hydration.state == :warming }

        latch << :go
        wait_until { hydration.done? }
        expect(hydration.state).to eq(:ready)
      end
    end

    it 'only arms a deferred hydration on the handshake; the transport starts it' do
      hydration = Woods::MCP::Hydration.new(mode: :after_handshake) { nil }
      hydration.defer_start_to_transport!
      hydration.handshake_answered!
      expect(hydration.state).to eq(:pending)

      hydration.start_if_armed!
      wait_until { hydration.done? }
      expect(hydration.state).to eq(:ready)
    end

    it 'leaves a plain SDK server alone' do
      plain = MCP::Server.new(name: 'plain', version: '1')
      expect { described_class.new(plain) }.not_to raise_error
    end
  end

  describe 'wait cap' do
    it 'defaults to 30 seconds and reads WOODS_MCP_HYDRATION_WAIT_SECONDS' do
      expect(described_class.new(mode: :after_handshake) { nil }.wait_cap).to eq(30.0)

      allow(ENV).to receive(:fetch).and_call_original
      allow(ENV).to receive(:fetch).with('WOODS_MCP_HYDRATION_WAIT_SECONDS', '').and_return('2.5')
      expect(described_class.new(mode: :after_handshake) { nil }.wait_cap).to eq(2.5)

      allow(ENV).to receive(:fetch).with('WOODS_MCP_HYDRATION_WAIT_SECONDS', '').and_return('nope')
      expect(described_class.new(mode: :after_handshake) { nil }.wait_cap).to eq(30.0)
    end
  end
end
