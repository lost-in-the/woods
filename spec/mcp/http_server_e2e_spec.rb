# frozen_string_literal: true

require 'spec_helper'
require 'fileutils'
require 'json'
require 'net/http'
require 'open3'
require 'socket'
require 'tmpdir'

# End-to-end coverage for `exe/woods-mcp-http` — the real executable, booted as
# a real process, driven over a real socket.
#
# Every other HTTP spec in this suite either reads the executable as text or
# drives `StreamableHTTPTransport` in-process. Neither can catch the class of
# bug that actually bit here: for a long time the binary could not boot at all,
# because no Rack handler was bundled and `Rackup::Handler.default` raised
# LoadError before serving a single request. A spec that never starts the
# process cannot see that.
#
# Tagged and excluded by default (it binds a port and shells out); the CI job
# and anyone validating the transport opts in:
#
#   WOODS_RUN_HTTP_SERVER=1 bin/rspec spec/mcp/http_server_e2e_spec.rb
#
RSpec.describe 'woods-mcp-http end to end', :http_server do
  let(:gem_root) { File.expand_path('../..', __dir__) }
  let(:executable) { File.join(gem_root, 'exe/woods-mcp-http') }

  # A port unlikely to collide with a developer's own services.
  let(:port) { 9_400 + (Process.pid % 100) }
  let(:base) { URI("http://127.0.0.1:#{port}/") }

  before(:all) do
    @index_dir = Dir.mktmpdir('woods-http-e2e')
    FileUtils.cp_r(File.join(File.expand_path('fixtures/woods', __dir__.sub(%r{/mcp\z}, '')), '.'), @index_dir)
  end

  after(:all) { FileUtils.rm_rf(@index_dir) if @index_dir }

  around do |example|
    start_server
    example.run
  ensure
    stop_server
  end

  let(:server_env) { {} }
  let(:stateless_env) { '1' }

  def start_server
    @stdin, @stdout, @wait = Open3.popen2e(
      {
        'PORT' => port.to_s,
        'HOST' => '127.0.0.1',
        'WOODS_MCP_HTTP_STATELESS' => stateless_env
      }.merge(server_env),
      'bundle', 'exec', 'ruby', executable, @index_dir, chdir: gem_root
    )
    wait_for_boot
  end

  def wait_for_boot(timeout: 30)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    loop do
      raise "server exited before binding:\n#{drain_output}" unless @wait.alive?

      begin
        Net::HTTP.start(base.host, base.port, open_timeout: 1, read_timeout: 1) { |h| h.head('/') }
        return
      rescue StandardError
        if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
          raise "server never bound to #{port}:\n#{drain_output}"
        end

        sleep 0.2
      end
    end
  end

  def drain_output
    @stdout.read_nonblock(20_000)
  rescue StandardError
    '(no output)'
  end

  def stop_server(signal = 'TERM')
    return unless @wait

    Process.kill(signal, @wait.pid) if @wait.alive?
    @wait.join(5)
  rescue Errno::ESRCH, Errno::ECHILD
    nil
  ensure
    [@stdin, @stdout].each { |io| io&.close unless io&.closed? }
    @stdin = @stdout = @wait = nil
  end

  def modern_meta
    {
      'io.modelcontextprotocol/protocolVersion' => '2026-07-28',
      'io.modelcontextprotocol/clientInfo' => { 'name' => 'spec-client', 'version' => '1.0' },
      'io.modelcontextprotocol/clientCapabilities' => {}
    }
  end

  def post(body, headers: {})
    body = body.dup
    unless body[:method] == 'initialize' || body['method'] == 'initialize'
      params = (body[:params] || body['params'] || {}).merge('_meta' => modern_meta)
      body[:params] = params
    end

    Net::HTTP.start(base.host, base.port) do |http|
      http.post(
        '/', JSON.generate(body),
        {
          'Content-Type' => 'application/json',
          'Accept' => 'application/json, text/event-stream',
          'MCP-Protocol-Version' => '2026-07-28',
          'Mcp-Method' => body[:method] || body['method']
        }.merge(headers)
      )
    end
  end

  def bare_request(klass)
    Net::HTTP.start(base.host, base.port) { |http| http.request(klass.new(base)) }
  end

  def raw_post(body, headers: {})
    Net::HTTP.start(base.host, base.port) do |http|
      request = Net::HTTP::Post.new(base)
      request.body = body
      request['Content-Type'] = 'application/json'
      request['Accept'] = 'application/json, text/event-stream'
      headers.each { |name, value| request[name] = value }
      http.request(request)
    end
  end

  describe 'the process' do
    it 'boots and binds without a Rack handler LoadError' do
      expect(@wait).to be_alive
    end
  end

  describe 'stateless mode (the default)' do
    it 'serves tools/list on a bare POST with no prior initialize' do
      response = post({ jsonrpc: '2.0', id: 1, method: 'tools/list', params: {} })
      expect(JSON.parse(response.body).dig('result', 'tools')).not_to be_empty
    end

    it 'issues no session header' do
      response = post({ jsonrpc: '2.0', id: 1, method: 'tools/list', params: {} })
      expect(response['mcp-session-id']).to be_nil
    end

    it 'carries the private cache scope over the wire' do
      response = post({ jsonrpc: '2.0', id: 1, method: 'tools/list', params: {} })
      expect(JSON.parse(response.body).dig('result', 'cacheScope')).to eq('private')
    end

    it 'answers server/discover with the modern revision' do
      response = post({ jsonrpc: '2.0', id: 1, method: 'server/discover', params: {} })
      expect(JSON.parse(response.body).dig('result', 'supportedVersions')).to include('2026-07-28')
    end

    it 'refuses the removed GET stream' do
      expect(bare_request(Net::HTTP::Get).code).to eq('405')
    end

    # The disconnect/reconnect property this whole change exists for: a client
    # holding a session id from before a restart is simply served, instead of
    # being told to start over.
    it 'serves a request carrying a stale session id instead of 404ing it' do
      response = post({ jsonrpc: '2.0', id: 1, method: 'tools/list', params: {} },
                      headers: { 'Mcp-Session-Id' => 'id-from-before-the-restart' })
      expect(response.code).to eq('200')
    end

    it 'still serves a legacy client that opens with initialize' do
      response = post({ jsonrpc: '2.0', id: 1, method: 'initialize',
                        params: { protocolVersion: '2024-11-05', capabilities: {},
                                  clientInfo: { name: 'legacy', version: '1' } } })
      expect(JSON.parse(response.body).dig('result', 'serverInfo', 'name')).to eq('woods')
    end

    it 'returns stable errors for malformed JSON and a removed legacy method' do
      malformed = raw_post('{"jsonrpc":')
      expect(malformed.code).to eq('400')
      expect(JSON.parse(malformed.body).dig('error', 'code')).to eq(-32_700)

      removed = post({ jsonrpc: '2.0', id: 2, method: 'resources/subscribe',
                       params: { uri: 'codebase://manifest' } })
      expect(JSON.parse(removed.body)['error']).to include(
        'code' => -32_601,
        'message' => a_string_matching(/not found/i)
      )
    end

    it 'recovers after a client interrupts a partial request body' do
      socket = TCPSocket.new(base.host, base.port)
      socket.write("POST / HTTP/1.1\r\nHost: #{base.host}:#{base.port}\r\n" \
                   "Content-Type: application/json\r\nContent-Length: 4096\r\n\r\n{\"jsonrpc\":")
      socket.close

      response = post({ jsonrpc: '2.0', id: 3, method: 'tools/list', params: {} })
      expect(response.code).to eq('200')
      expect(JSON.parse(response.body).dig('result', 'tools')).not_to be_empty
    ensure
      socket&.close unless socket&.closed?
    end

    it 'restarts after INT without retaining a process or stale session state' do
      first_pid = @wait.pid
      stop_server('INT')
      expect { Process.kill(0, first_pid) }.to raise_error(Errno::ESRCH)

      start_server
      response = post({ jsonrpc: '2.0', id: 4, method: 'tools/list', params: {} },
                      headers: { 'Mcp-Session-Id' => 'pre-restart-session' })
      expect(@wait.pid).not_to eq(first_pid)
      expect(response.code).to eq('200')
      expect(response['mcp-session-id']).to be_nil
    end
  end

  describe 'security middleware over the real socket' do
    let(:token) { 'task-4-http-token-0000000000000000' }
    let(:server_env) do
      {
        'WOODS_MCP_HTTP_TOKEN' => token,
        'WOODS_MCP_HTTP_ALLOWED_ORIGINS' => 'https://allowed.example'
      }
    end

    it 'enforces bearer auth, Origin, Host, and modern CORS headers' do
      expect(post({ jsonrpc: '2.0', id: 5, method: 'tools/list', params: {} }).code).to eq('401')

      authorized = post(
        { jsonrpc: '2.0', id: 6, method: 'tools/list', params: {} },
        headers: { 'Authorization' => "Bearer #{token}", 'Origin' => 'https://allowed.example' }
      )
      expect(authorized.code).to eq('200'), authorized.body

      rejected_origin = post(
        { jsonrpc: '2.0', id: 7, method: 'tools/list', params: {} },
        headers: { 'Authorization' => "Bearer #{token}", 'Origin' => 'https://rejected.example' }
      )
      expect(JSON.parse(rejected_origin.body).dig('error', 'message')).to eq('Origin not allowed')

      rejected_host = post(
        { jsonrpc: '2.0', id: 8, method: 'tools/list', params: {} },
        headers: { 'Authorization' => "Bearer #{token}", 'Host' => 'rebound.example' }
      )
      expect(JSON.parse(rejected_host.body).dig('error', 'message')).to eq('Host not allowed')

      preflight = Net::HTTP::Options.new(base)
      preflight['Origin'] = 'https://allowed.example'
      preflight['Access-Control-Request-Method'] = 'POST'
      preflight_response = Net::HTTP.start(base.host, base.port) { |http| http.request(preflight) }
      allowed_headers = preflight_response['access-control-allow-headers'].split(',').map(&:strip)
      expect(preflight_response.code).to eq('204')
      expect(allowed_headers).to include('MCP-Protocol-Version', 'Mcp-Method', 'Mcp-Name')
    end
  end

  describe 'the session-mode escape hatch' do
    let(:stateless_env) { '0' }

    it 'issues a session id again' do
      response = post({ jsonrpc: '2.0', id: 1, method: 'initialize',
                        params: { protocolVersion: '2025-06-18', capabilities: {},
                                  clientInfo: { name: 'legacy', version: '1' } } })
      expect(response['mcp-session-id']).not_to be_nil
    end
  end
end
