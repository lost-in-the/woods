# frozen_string_literal: true

require 'spec_helper'
require 'json'
require 'open3'
require 'tmpdir'

RSpec.describe 'Console transport boot configuration', :booted_app do
  let(:root) { File.expand_path('../..', __dir__) }
  let(:host) { File.join(root, 'spec/console/support/booted_console_app.rb') }

  def boot(http:, environment:, script: '', input: '', token: '', manual_mount: false, origins: nil)
    Dir.mktmpdir('woods-console-transport') do |directory|
      env = {
        'RAILS_ENV' => environment,
        'WOODS_DUMMY_DB' => File.join(directory, 'console.sqlite3'),
        'WOODS_CONSOLE_MCP_TOKEN' => token,
        'WOODS_TEST_CONSOLE_HTTP' => http ? '1' : '0',
        'WOODS_TEST_CONSOLE_MANUAL_MOUNT' => manual_mount ? '1' : '0',
        'WOODS_TEST_CONSOLE_ALLOWED_ORIGINS' => origins || (manual_mount ? 'https://trusted.example' : ''),
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

  def manual_mount_script
    <<~RUBY
      require 'rack/mock'
      require 'json'
      classes = Rails.application.middleware.map(&:klass).map(&:name)
      request = {jsonrpc: '2.0', id: 1, method: 'tools/list'}.to_json
      requests = {
        missing: {},
        wrong: {'HTTP_AUTHORIZATION' => 'Bearer incorrect'},
        authorized: {'HTTP_AUTHORIZATION' => "Bearer \#{ENV['WOODS_CONSOLE_MCP_TOKEN']}"},
        excluded_loopback: {'HTTP_AUTHORIZATION' => "Bearer \#{ENV['WOODS_CONSOLE_MCP_TOKEN']}",
                            'HTTP_ORIGIN' => 'http://localhost'},
        foreign: {'HTTP_AUTHORIZATION' => "Bearer \#{ENV['WOODS_CONSOLE_MCP_TOKEN']}",
                  'HTTP_ORIGIN' => 'https://foreign.example'}
      }
      responses = requests.transform_values do |headers|
        env = Rack::MockRequest.env_for('http://localhost/mcp/console', method: 'POST', input: request)
        env.update('CONTENT_TYPE' => 'application/json', 'HTTP_ACCEPT' => 'application/json, text/event-stream')
        status, _, body = Rails.application.call(env.merge(headers))
        text = +''
        body.each { |chunk| text << chunk }
        body.close if body.respond_to?(:close)
        {status: status, body: text}
      end
      puts JSON.generate(classes: classes, responses: responses)
    RUBY
  end

  it 'enforces HTTP guards when a legacy manual mount precedes the railtie stack' do
    out, err, status = boot(http: true, environment: 'test', manual_mount: true,
                            token: 'console-manual-mount-token-32-characters', script: manual_mount_script)

    expect(status).to be_success, err
    result = JSON.parse(out)
    expect(result['classes'].grep(/Woods::(?:Console::RackMiddleware|MCP::(?:OriginGuard|BearerAuth))/))
      .to eq(%w[Woods::Console::RackMiddleware Woods::MCP::OriginGuard Woods::MCP::BearerAuth
                Woods::Console::RackMiddleware])
    responses = result.fetch('responses')
    expect(responses.transform_values { |response| response['status'] })
      .to eq('missing' => 401, 'wrong' => 401, 'authorized' => 200, 'foreign' => 403, 'excluded_loopback' => 403)
    tools = JSON.parse(responses.dig('authorized', 'body')).dig('result', 'tools')
    expect(tools.length).to eq(9)
    expect(tools.map { |tool| tool['name'] }).to include('console_pluck')
  end

  it 'refuses missing-token HTTP access through a legacy manual mount despite the development warning' do
    out, err, status = boot(http: true, environment: 'test', manual_mount: true, script: manual_mount_script)

    expect(status).to be_success, err
    expect(err).to include('console_mcp_token is not set')
    responses = JSON.parse(out).fetch('responses')
    expect(responses.transform_values { |response| response['status'] })
      .to eq('missing' => 401, 'wrong' => 401, 'authorized' => 401, 'foreign' => 403, 'excluded_loopback' => 403)
  end

  [false, true].each do |manual_mount|
    it "names malformed origins during #{manual_mount ? 'manual' : 'automatic'} mount boot" do
      _out, err, status = boot(http: true, environment: 'test', manual_mount: manual_mount,
                               origins: 'invalid-entry', token: 'console-origin-policy-token-32-characters')

      expect(status).not_to be_success
      expect(err).to include('Woods::ConfigurationError', '[Woods Console]', 'invalid-entry')
    end

    it "shares preflight and SDK policy through the #{manual_mount ? 'manual' : 'automatic'} Rails mount" do
      script = <<~RUBY
        require 'rack/mock'
        require 'json'
        request = {jsonrpc: '2.0', id: 1, method: 'initialize', params: {
          protocolVersion: '2025-06-18', capabilities: {}, clientInfo: {name: 'origins', version: '1'}
        }}.to_json
        cases = [
          ['https://trusted.example', 'localhost', 200],
          ['https://trusted.example:4443', 'trusted.example:4443', 200],
          ['https://trusted.example:4443', 'localhost', 403],
          ['http://trusted.example:4443', 'trusted.example:4443', 403],
          ['https://[2001:db8::1]:4443', '[2001:db8::1]:4443', 200],
          [nil, 'trusted.example:4443', 200],
          ['http://localhost', 'localhost', 403],
          ['https://trusted.example', 'foreign.example', 403]
        ]
        results = cases.map do |origin, host, expected|
          statuses = %w[OPTIONS POST].map do |method|
            env = Rack::MockRequest.env_for('http://localhost/mcp/console', method: method, input: request)
            env.update('CONTENT_TYPE' => 'application/json', 'HTTP_ACCEPT' => 'application/json, text/event-stream',
                       'HTTP_HOST' => host, 'HTTP_AUTHORIZATION' => "Bearer \#{ENV['WOODS_CONSOLE_MCP_TOKEN']}")
            env['HTTP_ORIGIN'] = origin if origin
            status, _, body = Rails.application.call(env)
            text = +''
            body.each { |chunk| text << chunk }
            body.close if body.respond_to?(:close)
            raise "Not a successful initialization: \#{text}" if method == 'POST' && status == 200 &&
              !JSON.parse(text).dig('result', 'serverInfo')
            status
          end
          [expected, statuses]
        end
        puts JSON.generate(results)
      RUBY
      out, err, status = boot(http: true, environment: 'test', manual_mount: manual_mount,
                              origins: 'https://trusted.example,https://[2001:db8::1]',
                              token: 'console-origin-policy-token-32-characters', script: script)

      expect(status).to be_success, err
      expect(JSON.parse(out)).to all(satisfy do |expected, statuses|
        statuses == [expected == 200 ? 204 : expected, expected]
      end)
    end
  end
end
