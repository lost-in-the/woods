# frozen_string_literal: true

require 'spec_helper'
require 'json'
require 'net/http'
require 'open3'
require 'socket'
require 'timeout'
require 'tmpdir'
require 'woods/console/server'

RSpec.describe 'Console MCP HTTP end to end', :booted_app, :http_server do
  let(:root) { File.expand_path('../..', __dir__) }
  let(:host_script) { File.join(root, 'spec/console/support/booted_http_host.rb') }
  let(:rails_gemfile) { File.join(root, 'gemfiles/rails_8.1.gemfile') }

  around do |example|
    Dir.mktmpdir('woods-console-http') do |tmpdir|
      @database = File.join(tmpdir, 'console.sqlite3')
      @port = available_port
      start_process
      wait_for_boot
      example.run
    ensure
      stop_process
    end
  end

  def available_port
    socket = TCPServer.new('127.0.0.1', 0)
    socket.local_address.ip_port
  ensure
    socket&.close
  end

  def start_process
    environment = {
      'PATH' => ENV.fetch('PATH'),
      'BUNDLE_GEMFILE' => rails_gemfile,
      'HOST' => '127.0.0.1',
      'PORT' => @port.to_s,
      'WOODS_DUMMY_DB' => @database,
      'WOODS_CONSOLE_READ_TOOLS' => '0',
      'RAILS_ENV' => 'test'
    }
    environment['BUNDLE_PATH'] = ENV['BUNDLE_PATH'] if ENV['BUNDLE_PATH']
    @stdin, @output, @wait = Open3.popen2e(
      environment, 'bundle', 'exec', 'ruby', host_script, chdir: root
    )
  end

  def wait_for_boot
    Timeout.timeout(30) do
      loop do
        raise "HTTP host exited before binding:\n#{output}" unless @wait.alive?

        begin
          TCPSocket.new('127.0.0.1', @port).close
          break
        rescue Errno::ECONNREFUSED
          sleep 0.1
        end
      end
    end
  end

  def modern_meta
    {
      'io.modelcontextprotocol/protocolVersion' => '2026-07-28',
      'io.modelcontextprotocol/clientInfo' => { 'name' => 'console-http-e2e', 'version' => '1' },
      'io.modelcontextprotocol/clientCapabilities' => {}
    }
  end

  def post(method, params = {}, headers: {})
    params = params.merge('_meta' => modern_meta)
    request = Net::HTTP::Post.new('/mcp/console')
    request['Content-Type'] = 'application/json'
    request['Accept'] = 'application/json, text/event-stream'
    request['MCP-Protocol-Version'] = '2026-07-28'
    request['Mcp-Method'] = method
    request['Mcp-Name'] = params[:name] || params['name'] if method == 'tools/call'
    headers.each { |key, value| request[key] = value }
    request.body = JSON.generate(jsonrpc: '2.0', id: rand(1..1_000_000), method: method, params: params)

    response = Net::HTTP.start('127.0.0.1', @port, open_timeout: 2, read_timeout: 10) do |http|
      http.request(request)
    end
    [response, JSON.parse(response.body)]
  end

  def output
    @output.read_nonblock(20_000)
  rescue IO::WaitReadable, EOFError
    '(no output)'
  end

  def stop_process
    return unless @wait

    Process.kill('TERM', @wait.pid) if @wait.alive?
    Timeout.timeout(10) { @wait.value }
  rescue Errno::ESRCH, Errno::ECHILD
    nil
  ensure
    [@stdin, @output].each { |io| io&.close unless io&.closed? }
  end

  it 'serves concurrent stateless real queries and shuts down on TERM' do
    list_response, list = post('tools/list', headers: { 'Mcp-Session-Id' => 'stale-session' })
    expect(list_response['mcp-session-id']).to be_nil
    expect(list.dig('result', 'tools').map { |tool| tool['name'] }).to contain_exactly(
      *Woods::Console::Server::EXECUTABLE_MODES.fetch(:embedded)
    )

    results = Array.new(4) do
      Thread.new do
        params = { name: 'console_count', arguments: { model: 'Post' } }
        response, body = post('tools/call', params)
        { status: response.code, body: body }
      end
    end.map(&:value)
    expect(results).to all(
      satisfy do |result|
        result[:status] == '200' &&
          result[:body].dig('result', 'content', 0, 'text') == '**count:** 1'
      end
    )

    Process.kill('TERM', @wait.pid)
    status = Timeout.timeout(10) { @wait.value }
    expect(status.success? || status.termsig == Signal.list.fetch('TERM')).to be true
  end
end
