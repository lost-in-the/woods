# frozen_string_literal: true

require 'spec_helper'
require 'json'
require 'open3'
require 'tmpdir'

RSpec.describe 'Console transport boot configuration', :booted_app do
  let(:root) { File.expand_path('../..', __dir__) }
  let(:host) { File.join(root, 'spec/console/support/booted_console_app.rb') }

  def boot(http:, environment:, script: '', input: '')
    Dir.mktmpdir('woods-console-transport') do |directory|
      env = {
        'RAILS_ENV' => environment,
        'WOODS_DUMMY_DB' => File.join(directory, 'console.sqlite3'),
        'WOODS_CONSOLE_MCP_TOKEN' => '',
        'WOODS_TEST_CONSOLE_HTTP' => http ? '1' : '0',
        'WOODS_CONSOLE_READ_TOOLS' => '0'
      }
      Open3.capture3(env, RbConfig.ruby, '-Ilib', '-r', host, '-e', script,
                     stdin_data: input, chdir: root)
    end
  end

  it 'boots production stdio without an HTTP token and serves real tools over the pipe' do
    requests = [
      { jsonrpc: '2.0', id: 1, method: 'initialize', params: {
        protocolVersion: '2025-06-18', capabilities: {}, clientInfo: { name: 'transport-spec', version: '1' }
      } },
      { jsonrpc: '2.0', id: 2, method: 'tools/list' },
      { jsonrpc: '2.0', id: 3, method: 'tools/call', params: { name: 'console_count', arguments: { model: 'Post' } } }
    ]
    request_lines = requests.map { |request| JSON.generate(request) }.join("\n")
    out, err, status = boot(http: false, environment: 'production',
                            script: "load #{File.join(root, 'exe/woods-console').inspect}",
                            input: "#{request_lines}\n")

    expect(status).to be_success, err
    expect(err).not_to include('console_mcp_token')
    responses = out.lines.map { |line| JSON.parse(line) }
    expect(responses.find { |response| response['id'] == 2 }.dig('result', 'tools').length).to eq(9)
    expect(responses.find { |response| response['id'] == 3 }.dig('result', 'content', 0, 'text'))
      .to eq('**count:** 1')
  end

  it 'passes an HTTP request to Rails when HTTP Console is disabled' do
    script = <<~RUBY
      require 'rack/mock'
      response = Rails.application.call(Rack::MockRequest.env_for('http://localhost/mcp/console'))
      puts "STATUS=\#{response.first}"
    RUBY
    out, err, status = boot(http: false, environment: 'test', script: script)

    expect(status).to be_success, err
    expect(err).not_to include('console_mcp_token')
    expect(out).to include('STATUS=404')
  end

  it 'warns and rejects unauthenticated HTTP requests when HTTP Console is enabled' do
    script = <<~RUBY
      require 'rack/mock'
      response = Rails.application.call(Rack::MockRequest.env_for('http://localhost/mcp/console'))
      puts "STATUS=\#{response.first}"
    RUBY
    out, err, status = boot(http: true, environment: 'test', script: script)

    expect(status).to be_success, err
    expect(err).to include('console_mcp_token is not set')
    expect(out).to include('STATUS=401')
  end

  it 'still refuses production boot with HTTP Console enabled and no token' do
    _out, err, status = boot(http: true, environment: 'production')

    expect(status).not_to be_success
    expect(err).to include('Woods::ConfigurationError', 'console_mcp_token is not set')
  end
end
