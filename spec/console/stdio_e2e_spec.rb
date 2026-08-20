# frozen_string_literal: true

require 'spec_helper'
require 'json'
require 'open3'
require 'shellwords'
require 'timeout'
require 'tmpdir'
require 'yaml'
require 'woods/console/server'

RSpec.describe 'Console MCP stdio end to end', :booted_app do
  let(:root) { File.expand_path('../..', __dir__) }
  let(:executable) { File.join(root, 'exe/woods-console-mcp') }
  let(:host) { File.join(root, 'spec/console/support/booted_mcp_host.rb') }
  let(:rails_gemfile) { File.join(root, 'gemfiles/rails_8.1.gemfile') }

  around do |example|
    Dir.mktmpdir('woods-console-stdio') do |tmpdir|
      @tmpdir = tmpdir
      @database = File.join(tmpdir, 'console.sqlite3')
      @config = File.join(tmpdir, 'console.yml')
      command = Shellwords.join(['bundle', 'exec', 'ruby', host])
      File.write(@config, YAML.dump('mode' => 'direct', 'directory' => root, 'command' => command))
      example.run
    ensure
      stop_process
    end
  end

  def start_process(read_tools: true)
    environment = {
      'PATH' => ENV.fetch('PATH'),
      'BUNDLE_GEMFILE' => rails_gemfile,
      'HOME' => @tmpdir,
      'WOODS_CONSOLE_CONFIG' => @config,
      'WOODS_DUMMY_DB' => @database,
      'WOODS_CONSOLE_READ_TOOLS' => read_tools ? '1' : '0',
      'RAILS_ENV' => 'test'
    }
    environment['BUNDLE_PATH'] = ENV['BUNDLE_PATH'] if ENV['BUNDLE_PATH']
    @stdin, @stdout, @stderr, @wait = Open3.popen3(environment, executable, chdir: root)
  end

  def rpc(method, params = {})
    @request_id = @request_id.to_i + 1
    @stdin.puts(JSON.generate(jsonrpc: '2.0', id: @request_id, method: method, params: params))
    @stdin.flush
    Timeout.timeout(30) { JSON.parse(@stdout.gets || raise("server closed:\n#{stderr_output}")) }
  end

  def initialize_session
    rpc(
      'initialize',
      protocolVersion: '2025-06-18',
      capabilities: {},
      clientInfo: { name: 'console-e2e', version: '1' }
    )
  end

  def call_tool(name, arguments)
    response = rpc('tools/call', name: name, arguments: arguments)
    response.dig('result', 'content', 0, 'text')
  end

  def stderr_output
    @stderr.read_nonblock(20_000)
  rescue IO::WaitReadable, EOFError
    '(no stderr output)'
  end

  def stop_process
    return unless @wait

    Process.kill('TERM', @wait.pid) if @wait.alive?
    Timeout.timeout(10) { @wait.value }
  rescue Errno::ESRCH, Errno::ECHILD
    nil
  ensure
    [@stdin, @stdout, @stderr].each { |io| io&.close unless io&.closed? }
  end

  it 'executes real supported tools, survives malformed input, and exits on EOF' do
    start_process
    expect(initialize_session.dig('result', 'serverInfo', 'name')).to eq('woods-console')

    list = rpc('tools/list')
    expect(list.dig('result', 'tools').map { |tool| tool['name'] }).to contain_exactly(
      *Woods::Console::Server::EXECUTABLE_MODES.fetch(:embedded_read)
    )
    expect(call_tool('console_count', 'model' => 'Post')).to eq('**count:** 1')

    query = call_tool(
      'console_query',
      'model' => 'Post', 'select' => %w[id title], 'order' => { 'id' => 'asc' }
    )
    expect(query).to include('**count:** 1')
    expect(query).to include('| 1 | Console contract row |')

    @stdin.puts('{not-json')
    @stdin.flush
    malformed = Timeout.timeout(5) { JSON.parse(@stdout.gets) }
    expect(malformed.dig('error', 'code')).to eq(-32_700)
    expect(rpc('tools/list').dig('result', 'tools')).not_to be_empty

    @stdin.close
    status = Timeout.timeout(10) { @wait.value }
    expect(status).to be_success
  end

  it 'executes a real query through the default 9-tool mode' do
    start_process(read_tools: false)
    initialize_session

    list = rpc('tools/list')
    expect(list.dig('result', 'tools').map { |tool| tool['name'] }).to contain_exactly(
      *Woods::Console::Server::EXECUTABLE_MODES.fetch(:embedded)
    )
    expect(call_tool('console_count', 'model' => 'Post')).to eq('**count:** 1')

    @stdin.close
    expect(Timeout.timeout(10) { @wait.value }).to be_success
  end

  it 'exits with the interrupt status when the client sends INT' do
    start_process
    initialize_session

    Process.kill('INT', @wait.pid)
    status = Timeout.timeout(10) { @wait.value }

    expect(status.exitstatus).to eq(130)
  end
end
