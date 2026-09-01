# frozen_string_literal: true

require 'spec_helper'
require 'fileutils'
require 'json'
require 'mcp'
require 'net/http'
require 'open3'
require 'socket'
require 'tmpdir'
require 'timeout'
require 'woods/mcp/tasks/store'

# The official transport drains the child's stderr through a background
# thread that discards every chunk it reads, so a timeout failure carries no
# child context. This subclass mirrors Stdio#start with one addition: each
# drained chunk is teed into a spec-local buffer that the timeout diagnostics
# below read. Mirroring start (rather than wrapping it) is what lets the tee
# exist from the first drained byte.
class StdioCapturingStderr < MCP::Client::Stdio
  def start
    raise 'MCP::Client::Stdio already started' if @started

    @stdin, @stdout, @stderr, @wait_thread = Open3.popen3(@env || {}, @command, *@args)
    @stdout.set_encoding('UTF-8')
    @stdin.set_encoding('UTF-8')
    @captured_stderr = String.new(encoding: Encoding::UTF_8)
    @stderr_capture_mutex = Mutex.new
    drain_server_stderr
    @started = true
  rescue Errno::ENOENT, Errno::EACCES, Errno::ENOEXEC => e
    raise MCP::Client::RequestHandlerError.new(
      "Failed to spawn server process: #{e.message}", {},
      error_type: :internal_error, original_error: e
    )
  end

  def captured_stderr_text
    @stderr_capture_mutex.synchronize { @captured_stderr.dup }
  end

  private

  def drain_server_stderr
    @stderr_thread = Thread.new do
      loop do
        chunk = @stderr.readpartial(STDERR_READ_SIZE)
        @stderr_capture_mutex.synchronize do
          @captured_stderr << chunk.force_encoding(Encoding::UTF_8)
        end
      end
    rescue IOError
      nil
    end
  end
end

RSpec.describe 'MCP executable contract with the official Ruby client' do
  gem_root = File.expand_path('../..', __dir__)
  fixture_dir = File.join(gem_root, 'spec/fixtures/woods')
  protocol_version = '2026-07-28'
  client_info = { name: 'woods-task-4-contract', version: '1.0' }.freeze

  def assert_modern_contract(client, discovery, protocol_version)
    assert_discovery_contract(client, discovery, protocol_version)
    assert_tool_contract(client)
  end

  def assert_discovery_contract(client, discovery, protocol_version)
    expect(client.protocol_version).to eq(protocol_version)
    expect(discovery.fetch('supportedVersions')).to include(protocol_version)
    expect(discovery.fetch('cacheScope')).to eq('private')
    expect(discovery.dig('_meta', 'io.modelcontextprotocol/serverInfo', 'name')).to eq('woods')
  end

  def assert_tool_contract(client)
    tools = client.tools
    expect(tools.map(&:name)).to include('lookup', 'woods_status')
    expect(tools.find { |tool| tool.name == 'lookup' }.output_schema).to be_a(Hash)

    response = client.call_tool(name: 'lookup', arguments: { identifier: 'Post' })
    expect(response.dig('result', 'isError')).not_to be(true)
    expect(response.dig('result', 'structuredContent', 'text')).to include('Post')
  end

  # A read timeout surfaces as RequestHandlerError with no child context: the
  # official transport discards stderr as it drains it. Returns the same
  # error, or a copy carrying whatever the spec transport captured, so the
  # timeout failure is diagnosable from the logs. Every other error passes
  # through untouched.
  def with_child_stderr_context(error, transport)
    return error unless error.message.include?('Timed out waiting for server response')
    return error unless transport.respond_to?(:captured_stderr_text)

    stderr = transport.captured_stderr_text.strip
    diagnostic = stderr.empty? ? '(child stderr was empty)' : stderr
    augmented = error.class.new(
      "#{error.message}\nchild stderr captured by the spec transport:\n#{diagnostic}",
      error.request,
      error_type: error.error_type,
      original_error: error.original_error
    )
    augmented.set_backtrace(error.backtrace)
    augmented
  end

  # Evidence path for the intermittent full-suite flake: random-order runs
  # have failed this and the Tasks example below with RequestHandlerError
  # "Timed out waiting for server response", while the same examples pass
  # isolated (multiple seeds and formatters), in defined order, in the
  # 242-file complement, and under synthetic load. The timeout here mirrors
  # the HTTP examples' 30s budget. On a timeout the example fails once with
  # the child's captured stderr appended to the failure message —
  # deterministic, visible in CI logs, with no rerun to hide the evidence.
  # No cause is claimed. The malformed-frame example below still proves the
  # spawn/reap contract unconditionally.
  it 'drives packaged woods-mcp in modern mode and reaps it on EOF' do
    transport = StdioCapturingStderr.new(
      command: 'bundle',
      args: ['exec', 'ruby', 'exe/woods-mcp', fixture_dir],
      env: {
        'PATH' => ENV.fetch('PATH'),
        'BUNDLE_GEMFILE' => File.join(gem_root, 'Gemfile'),
        'BUNDLE_PATH' => ENV.fetch('BUNDLE_PATH', nil)
      }.compact,
      read_timeout: 30
    )
    client = MCP::Client.new(transport: transport)

    discovery = client.connect(
      client_info: client_info,
      protocol_version: protocol_version,
      mode: :modern
    )
    wait_thread = transport.instance_variable_get(:@wait_thread)
    assert_modern_contract(client, discovery, protocol_version)

    transport.close
    expect(wait_thread).not_to be_alive
  rescue MCP::Client::RequestHandlerError => e
    raise with_child_stderr_context(e, transport)
  ensure
    transport&.close
  end

  # Same evidence path as the example above: on timeout the example fails
  # once with the child's captured stderr appended to the failure message.
  it 'drives modern Tasks methods through the official transport metadata path' do
    Dir.mktmpdir('woods-ruby-client-tasks') do |index_dir|
      FileUtils.cp_r(File.join(fixture_dir, '.'), index_dir)
      task = Woods::MCP::Tasks::Store.new(index_dir).create!(tool: 'pipeline_extract')
      transport = StdioCapturingStderr.new(
        command: 'bundle',
        args: ['exec', 'ruby', 'exe/woods-mcp', index_dir],
        env: {
          'PATH' => ENV.fetch('PATH'),
          'BUNDLE_GEMFILE' => File.join(gem_root, 'Gemfile'),
          'BUNDLE_PATH' => ENV.fetch('BUNDLE_PATH', nil)
        }.compact,
        read_timeout: 30
      )
      client = MCP::Client.new(transport: transport)
      capabilities = { extensions: { 'io.modelcontextprotocol/tasks' => {} } }
      discovery = client.connect(
        client_info: client_info,
        protocol_version: protocol_version,
        capabilities: capabilities,
        mode: :modern
      )
      expect(discovery.dig('capabilities', 'extensions')).to include('io.modelcontextprotocol/tasks')

      get = send_custom_request(transport, 20, 'tasks/get', taskId: task.id)
      expect(get.dig('result', 'taskId')).to eq(task.id)
      expect(get.dig('result', 'status')).to eq('working')

      update = send_custom_request(transport, 21, 'tasks/update', taskId: task.id, inputResponses: {})
      expect(update.fetch('result')).to eq('resultType' => 'complete')

      cancel = send_custom_request(transport, 22, 'tasks/cancel', taskId: task.id)
      expect(cancel.fetch('error')).to include(
        'code' => -32_601,
        'data' => 'Task cancellation is not supported by Woods.'
      )
    rescue MCP::Client::RequestHandlerError => e
      raise with_child_stderr_context(e, transport)
    ensure
      transport&.close
    end
  end

  # Regression guard for the evidence path: a timeout through the capturing
  # transport must surface the child's stderr in the failure message. The
  # child streams a known marker on stderr and never answers stdout, so a
  # short read_timeout forces the same timeout signature the two contract
  # examples arm diagnostics for, at a fraction of their budget.
  it 'surfaces captured child stderr when a read times out' do
    transport = StdioCapturingStderr.new(
      command: RbConfig.ruby,
      args: ['-e', 'loop { warn "WOODS_STDERR_MARKER"; sleep 0.05 }'],
      env: { 'PATH' => ENV.fetch('PATH') },
      read_timeout: 2
    )
    client = MCP::Client.new(transport: transport)

    failure = nil
    begin
      client.connect(client_info: client_info, protocol_version: protocol_version, mode: :modern)
    rescue MCP::Client::RequestHandlerError => e
      failure = with_child_stderr_context(e, transport)
    ensure
      transport.close
    end

    expect(failure).to be_a(MCP::Client::RequestHandlerError)
    expect(failure.message).to include('Timed out waiting for server response')
    expect(failure.message).to include('WOODS_STDERR_MARKER')
  end

  def send_custom_request(transport, id, method, params)
    transport.send_request(
      request: { jsonrpc: '2.0', id: id, method: method, params: params }
    )
  end

  it 'recovers from a malformed stdio frame and rejects a removed legacy method before EOF' do
    env = {
      'PATH' => ENV.fetch('PATH'),
      'BUNDLE_GEMFILE' => File.join(gem_root, 'Gemfile'),
      'BUNDLE_PATH' => ENV.fetch('BUNDLE_PATH', nil)
    }.compact
    stdin, stdout, stderr, wait_thread = Open3.popen3(
      env, 'bundle', 'exec', 'ruby', 'exe/woods-mcp', fixture_dir, chdir: gem_root
    )

    stdin.puts('{"jsonrpc":')
    parse_error = JSON.parse(Timeout.timeout(10) { stdout.gets })
    expect(parse_error.fetch('error')).to include('code' => -32_700)

    meta = {
      'io.modelcontextprotocol/protocolVersion' => protocol_version,
      'io.modelcontextprotocol/clientInfo' => client_info.transform_keys(&:to_s),
      'io.modelcontextprotocol/clientCapabilities' => {}
    }
    stdin.puts(JSON.generate(
                 jsonrpc: '2.0', id: 2, method: 'resources/subscribe',
                 params: { uri: 'codebase://manifest', '_meta' => meta }
               ))
    removed = JSON.parse(Timeout.timeout(10) { stdout.gets })
    expect(removed.fetch('error')).to include('code' => -32_601)

    stdin.close
    expect(wait_thread.join(5)).not_to be_nil
    expect(wait_thread).not_to be_alive
  ensure
    stdin&.close unless stdin&.closed?
    [stdout, stderr].each { |io| io&.close unless io&.closed? }
    Process.kill('TERM', wait_thread.pid) if wait_thread&.alive?
    wait_thread&.join(5)
  end

  describe 'packaged woods-mcp-http', :http_server do
    def free_port
      server = TCPServer.new('127.0.0.1', 0)
      server.local_address.ip_port
    ensure
      server&.close
    end

    def wait_for_http(base, wait_thread, output, timeout: 30)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      loop do
        raise "server exited before binding:\n#{output.read}" unless wait_thread.alive?

        begin
          Net::HTTP.start(base.host, base.port, open_timeout: 1, read_timeout: 1) { |http| http.head('/') }
          return
        rescue StandardError
          raise "server never bound to #{base}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

          sleep 0.1
        end
      end
    end

    def stop_http_server(wait_thread, stdin, output)
      terminate_process(wait_thread)
    ensure
      close_ios(stdin, output)
    end

    def terminate_process(wait_thread)
      return unless wait_thread

      Process.kill('TERM', wait_thread.pid) if wait_thread.alive?
      wait_thread.join(5)
      if wait_thread.alive?
        Process.kill('KILL', wait_thread.pid)
        wait_thread.join(5)
      end
      expect(wait_thread).not_to be_alive
    rescue Errno::ESRCH, Errno::ECHILD
      nil
    end

    def close_ios(*ios)
      ios.compact.each { |io| io.close unless io.closed? }
    end

    def start_http_server(gem_root, fixture_dir, extra_env = {})
      port = free_port
      base = URI("http://127.0.0.1:#{port}/")
      env = {
        'PORT' => port.to_s,
        'HOST' => '127.0.0.1',
        'WOODS_MCP_HTTP_STATELESS' => '1',
        'BUNDLE_GEMFILE' => File.join(gem_root, 'Gemfile')
      }.merge(extra_env)
      stdin, output, wait_thread = Open3.popen2e(
        env, 'bundle', 'exec', 'ruby', 'exe/woods-mcp-http', fixture_dir, chdir: gem_root
      )
      wait_for_http(base, wait_thread, output)
      [base, stdin, output, wait_thread]
    rescue StandardError
      stop_http_server(wait_thread, stdin, output)
      raise
    end

    def expect_policy_rejection(base, headers, client_info, protocol_version, type)
      transport = MCP::Client::HTTP.new(url: base.to_s, headers: headers)
      client = MCP::Client.new(transport: transport)
      error = capture_request_error do
        client.connect(client_info: client_info, protocol_version: protocol_version, mode: :modern)
      end

      expect(error).to be_a(MCP::Client::RequestHandlerError)
      expect(error.error_type).to eq(type)
    ensure
      transport&.close
    end

    def capture_request_error
      yield
    rescue MCP::Client::RequestHandlerError => e
      e
    end

    it 'drives a real stateless HTTP socket in modern mode' do
      base, stdin, output, wait_thread = start_http_server(gem_root, fixture_dir)

      transport = MCP::Client::HTTP.new(url: base.to_s)
      client = MCP::Client.new(transport: transport)
      discovery = client.connect(
        client_info: client_info,
        protocol_version: protocol_version,
        mode: :modern
      )
      assert_modern_contract(client, discovery, protocol_version)
      expect(transport.session_id).to be_nil
    ensure
      transport&.close
      stop_http_server(wait_thread, stdin, output)
    end

    it 'reaps the HTTP child inside the spawn helper when readiness fails' do
      child = nil
      allow(self).to receive(:wait_for_http) do |_base, wait_thread, _output, **_options|
        child = wait_thread
        raise Timeout::Error, 'forced readiness timeout'
      end

      expect { start_http_server(gem_root, fixture_dir) }
        .to raise_error(Timeout::Error, 'forced readiness timeout')
      expect(child).not_to be_alive
    end

    it 'exercises auth, Origin, and Host policy through the supported headers API' do
      token = 'task-4-ruby-client-token-0000000000000000'
      allowed_origin = 'https://allowed.example'
      base, stdin, output, wait_thread = start_http_server(
        gem_root,
        fixture_dir,
        'WOODS_MCP_HTTP_TOKEN' => token,
        'WOODS_MCP_HTTP_ALLOWED_ORIGINS' => allowed_origin
      )
      authorized_transport = MCP::Client::HTTP.new(
        url: base.to_s,
        headers: { 'Authorization' => "Bearer #{token}", 'Origin' => allowed_origin }
      )
      authorized_client = MCP::Client.new(transport: authorized_transport)
      authorized_client.connect(client_info: client_info, protocol_version: protocol_version, mode: :modern)
      expect(authorized_client.tools.map(&:name)).to include('lookup')

      expect_policy_rejection(
        base, { 'Origin' => allowed_origin }, client_info, protocol_version, :unauthorized
      )
      expect_policy_rejection(
        base,
        { 'Authorization' => "Bearer #{token}", 'Origin' => 'https://rejected.example' },
        client_info, protocol_version, :forbidden
      )
      expect_policy_rejection(
        base,
        { 'Authorization' => "Bearer #{token}", 'Origin' => allowed_origin, 'Host' => 'rebound.example' },
        client_info, protocol_version, :forbidden
      )
    ensure
      authorized_transport&.close
      stop_http_server(wait_thread, stdin, output)
    end
  end
end
