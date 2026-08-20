# frozen_string_literal: true

require 'spec_helper'
require 'fileutils'
require 'json'
require 'net/http'
require 'open3'
require 'socket'
require 'tmpdir'

RSpec.describe 'official MCP Inspector v2 contract', :mcp_inspector do
  let(:gem_root) { File.expand_path('../..', __dir__) }
  let(:fixture_dir) { File.join(gem_root, 'spec/fixtures/woods') }
  let(:inspector) { File.join(gem_root, 'node_modules/.bin/mcp-inspector') }
  let(:server_name) { 'woods-task-4' }

  around do |example|
    Dir.mktmpdir('woods-inspector-contract') do |dir|
      @inspector_home = dir
      @config_path = File.join(dir, 'mcp.json')
      example.run
    end
  end

  def inspector_env
    {
      'HOME' => @inspector_home,
      'MCP_CLIENT_CONFIG_PATH' => File.join(@inspector_home, 'client.json')
    }
  end

  def write_inspector_config(server, protocol_era:)
    File.write(
      @config_path,
      JSON.pretty_generate('mcpServers' => { server_name => server.merge('protocolEra' => protocol_era) })
    )
  end

  def capture_inspector(method, *arguments)
    command = [
      inspector, '--cli', '--config', @config_path, '--server', server_name,
      '--method', method, '--format', 'json', *arguments
    ]
    stdout, stderr, status = Open3.capture3(inspector_env, *command, chdir: gem_root)
    [command, stdout, stderr, status]
  end

  def run_inspector(method, *arguments)
    command, stdout, stderr, status = capture_inspector(method, *arguments)
    expect(status).to be_success, <<~MESSAGE
      Inspector failed (#{status.exitstatus}): #{command.join(' ')}
      stdout: #{stdout}
      stderr: #{stderr}
    MESSAGE
    JSON.parse(stdout).fetch('result')
  end

  def assert_inspector_surface
    assert_inspector_initialization
    assert_inspector_tools
    assert_inspector_resources
  end

  def assert_inspector_initialization
    initialized = run_inspector('initialize')
    expect(initialized).to include(
      'protocolVersion' => '2025-11-25',
      'serverInfo' => include('name' => 'woods', 'version' => Woods::VERSION)
    )
  end

  def assert_inspector_tools
    tools = run_inspector('tools/list').fetch('tools')
    lookup = tools.find { |tool| tool.fetch('name') == 'lookup' }
    expect(lookup.fetch('inputSchema').fetch('additionalProperties')).to be(false)
    expect(lookup.fetch('outputSchema').fetch('required')).to include('text')

    called = run_inspector('tools/call', '--tool-name', 'lookup', '--tool-args-json', '{"identifier":"Post"}')
    expect(called.fetch('isError', false)).to be(false)
    expect(called.dig('structuredContent', 'text')).to include('Post')
  end

  def assert_inspector_resources
    assert_inspector_resource_list
    assert_inspector_manifest
    assert_inspector_resource_templates
  end

  def assert_inspector_resource_list
    resources = run_inspector('resources/list').fetch('resources')
    expect(resources.map { |resource| resource.fetch('uri') }).to contain_exactly(
      'codebase://manifest', 'codebase://graph'
    )
  end

  def assert_inspector_manifest
    manifest = run_inspector('resources/read', '--uri', 'codebase://manifest')
    expect(manifest.dig('contents', 0, 'mimeType')).to eq('application/json')
    parsed_manifest = JSON.parse(manifest.dig('contents', 0, 'text'))
    expect(parsed_manifest.fetch('counts')).not_to be_empty
    expect(parsed_manifest.fetch('total_units')).to be_positive
  end

  def assert_inspector_resource_templates
    templates = run_inspector('resources/templates/list').fetch('resourceTemplates')
    expect(templates.map { |template| template.fetch('uriTemplate') }).to contain_exactly(
      'codebase://unit/{identifier}', 'codebase://type/{type}'
    )
  end

  def assert_modern_inspector_limitation
    _command, _stdout, stderr, status = capture_inspector('initialize')
    expect(status).not_to be_success
    expect(stderr).to include(
      "Method 'logging/setLevel' is not supported by the negotiated protocol version (wire era 2026-07-28)"
    )
  end

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
  rescue Errno::ESRCH, Errno::ECHILD
    nil
  end

  def close_ios(*ios)
    ios.compact.each { |io| io.close unless io.closed? }
  end

  it 'records the modern stdio limitation and validates Inspector through its legacy fallback' do
    server = {
      'type' => 'stdio',
      'command' => 'bundle',
      'args' => ['exec', 'ruby', 'exe/woods-mcp', fixture_dir],
      'cwd' => gem_root,
      'env' => {
        'PATH' => ENV.fetch('PATH'),
        'BUNDLE_GEMFILE' => File.join(gem_root, 'Gemfile'),
        'BUNDLE_PATH' => ENV.fetch('BUNDLE_PATH', nil)
      }.compact
    }

    write_inspector_config(server, protocol_era: 'modern')
    assert_modern_inspector_limitation
    write_inspector_config(server, protocol_era: 'legacy')
    assert_inspector_surface
  end

  it 'records the modern HTTP limitation and validates Inspector through its legacy fallback' do
    token = 'task-4-inspector-token-0000000000000000'
    allowed_origin = 'https://allowed.example'
    port = free_port
    base = URI("http://127.0.0.1:#{port}/")
    stdin, output, wait_thread = Open3.popen2e(
      {
        'PORT' => port.to_s,
        'HOST' => '127.0.0.1',
        'WOODS_MCP_HTTP_STATELESS' => '1',
        'WOODS_MCP_HTTP_TOKEN' => token,
        'WOODS_MCP_HTTP_ALLOWED_ORIGINS' => allowed_origin,
        'BUNDLE_GEMFILE' => File.join(gem_root, 'Gemfile')
      },
      'bundle', 'exec', 'ruby', 'exe/woods-mcp-http', fixture_dir,
      chdir: gem_root
    )
    wait_for_http(base, wait_thread, output)
    server = {
      'type' => 'streamable-http',
      'url' => base.to_s,
      'headers' => { 'Authorization' => "Bearer #{token}", 'Origin' => allowed_origin }
    }

    write_inspector_config(server, protocol_era: 'modern')
    assert_modern_inspector_limitation
    write_inspector_config(server, protocol_era: 'legacy')
    assert_inspector_surface
  ensure
    stop_http_server(wait_thread, stdin, output)
  end

  it 'records the one-shot CLI limitation for discovery and Tasks instead of faking coverage' do
    package = JSON.parse(File.read(File.join(gem_root, 'node_modules/@modelcontextprotocol/inspector/package.json')))
    expect(package.fetch('version')).to eq('2.2.0')

    _stdout, stderr, status = Open3.capture3(
      inspector_env,
      inspector, '--cli', '--method', 'server/discover', '--format', 'json',
      chdir: gem_root
    )
    expect(status).not_to be_success
    expect(stderr).to include('Unsupported method: server/discover')
    expect(stderr).to include('Supported --cli methods: initialize, tools/list, tools/call')
    expect(stderr).not_to include('tasks/get')
  end
end
