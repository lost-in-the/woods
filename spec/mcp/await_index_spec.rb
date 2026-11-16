# frozen_string_literal: true

require 'spec_helper'
require 'fileutils'
require 'json'
require 'open3'
require 'tmpdir'
require 'mcp'
require 'woods'
require 'woods/mcp/server'
require_relative '../support/quiet_git'

# A server started with `await_index: true` before any index exists: it
# completes the handshake, registers its tools, answers a retryable
# `building` result, and serves the first generation when one appears.
RSpec.describe 'Index MCP server awaiting its first index' do
  let(:fixture_dir) { File.expand_path('../fixtures/woods', __dir__) }

  around do |example|
    Dir.mktmpdir('woods-await-index') do |directory|
      @base = File.realpath(directory)
      @index = File.join(@base, 'tmp', 'woods')
      example.run
    end
  end

  before { Woods.configuration = Woods::Configuration.new }

  def build(index_dir = @index, **options)
    Woods::MCP::Server.build(index_dir: index_dir, response_format: :json, warmup: false, **options)
  end

  def rpc(server, method, params = {})
    JSON.parse(server.handle_json(JSON.generate(jsonrpc: '2.0', id: 1, method: method, params: params)))
  end

  def initialize_result(server)
    rpc(server, 'initialize', protocolVersion: '2025-06-18', capabilities: {},
                              clientInfo: { name: 'await-spec', version: '1' }).fetch('result')
  end

  def call(server, name, arguments = {})
    rpc(server, 'tools/call', name: name, arguments: arguments)
  end

  def status(server)
    JSON.parse(call(server, 'woods_status').dig('result', 'content', 0, 'text'))
  end

  def publish(number: 1, payload: "payloads/gen-#{number}", write_payload: true)
    FileUtils.mkdir_p(File.join(@index, File.dirname(payload)))
    FileUtils.cp_r(fixture_dir, File.join(@index, payload)) if write_payload
    File.write(File.join(@index, 'generation.json'),
               JSON.generate(number: number, token: "t#{number}", updated_at: '2026-11-01T10:00:00Z',
                             payload: payload))
  end

  def expect_building(response, tool)
    result = response.fetch('result')
    expect(result['isError']).to be(false)
    expect(result.dig('structuredContent', 'data')).to include('status' => 'building', 'retryable' => true,
                                                               'tool' => tool)
    expect(result.dig('structuredContent', 'data', 'retry_after_seconds')).to be_a(Integer)
    expect(result.dig('content', 0, 'text')).to include('Not answered yet', 'woods_status', @index)
    schema = MCP::Tool::OutputSchema.new(Woods::MCP::ToolContract::OUTPUT_SCHEMA)
    expect { schema.validate_result(result.fetch('structuredContent')) }.not_to raise_error
  end

  it 'still refuses a missing index without await_index' do
    expect { build }.to raise_error(ArgumentError, /Index directory does not exist/)
  end

  it 'answers initialize and lists exactly the tools a server over an index lists, in the same order' do
    server = build(await_index: true)

    result = initialize_result(server)
    awaiting_tools = rpc(server, 'tools/list').dig('result', 'tools')
    indexed_tools = rpc(build(fixture_dir), 'tools/list').dig('result', 'tools')

    expect(result.dig('serverInfo', 'name')).to eq('woods')
    expect(result.fetch('instructions')).to include("No index was published in #{@index} when this server started")
    expect(result.fetch('instructions').bytesize).to be <= Woods::MCP::InitializationGuidance::MAX_BYTES
    expect(awaiting_tools).to eq(indexed_tools)
    expect(File.exist?(@index)).to be(false)
  end

  it 'reports what it is waiting for in woods_status' do
    server = build(await_index: true)

    report = status(server)

    expect(report).to include('ready' => false)
    expect(report.fetch('index')).to include('state' => 'awaiting_index', 'watching' => @index, 'bootstrap' => nil)
    expect(Time.iso8601(report.dig('index', 'awaiting_since'))).to be_within(60).of(Time.now)
    expect(report.dig('server', 'index_dir')).to eq(@index)
    expect(report).to have_key('identity')
    expect(report.fetch('hydration')).to include('state' => 'ready')
  end

  it 'answers every other tool with a retryable building result, and an unknown tool as before' do
    server = build(await_index: true)

    expect_building(call(server, 'lookup', identifier: 'Post'), 'lookup')
    expect_building(call(server, 'search', query: 'Post'), 'search')
    expect_building(call(server, 'reload'), 'reload')
    expect(call(server, 'no_such_tool')).to eq(call(build(fixture_dir), 'no_such_tool'))
  end

  it 'refuses a resource read with a retryable index_building error' do
    server = build(await_index: true)

    error = rpc(server, 'resources/read', uri: 'codebase://manifest').fetch('error')

    expect(error.dig('data', 'error_code')).to eq('index_building')
  end

  it 'serves the first published generation on the next call, without a restart' do
    server = build(await_index: true)
    expect_building(call(server, 'lookup', identifier: 'Post'), 'lookup')

    publish

    answer = call(server, 'lookup', identifier: 'Post').fetch('result')
    expect(answer['isError']).to be(false)
    expect(answer.dig('content', 0, 'text')).to include('Post')
    expect(status(server)).to include('ready' => true)
    expect(status(server).dig('identity', 'generation')).to eq(1)
  end

  it 'serves a flat index written in place' do
    server = build(await_index: true)
    expect_building(call(server, 'lookup', identifier: 'Post'), 'lookup')

    FileUtils.mkdir_p(File.dirname(@index))
    FileUtils.cp_r(fixture_dir, @index)

    expect(call(server, 'lookup', identifier: 'Post').dig('result', 'isError')).to be(false)
  end

  it 'keeps answering building while generation.json names a payload that is not there yet' do
    server = build(await_index: true)
    publish(write_payload: false)

    expect_building(call(server, 'lookup', identifier: 'Post'), 'lookup')
    expect(status(server).dig('index', 'state')).to eq('awaiting_index')

    FileUtils.cp_r(fixture_dir, File.join(@index, 'payloads', 'gen-1'))

    expect(call(server, 'lookup', identifier: 'Post').dig('result', 'isError')).to be(false)
  end

  it 'starts over an existing empty index directory' do
    FileUtils.mkdir_p(@index)
    server = build(await_index: true)

    expect_building(call(server, 'lookup', identifier: 'Post'), 'lookup')
    publish

    expect(call(server, 'lookup', identifier: 'Post').dig('result', 'isError')).to be(false)
  end

  it 'answers corruption after the first generation as corruption, never as building' do
    server = build(await_index: true)
    publish
    expect(call(server, 'lookup', identifier: 'Post').dig('result', 'isError')).to be(false)

    File.write(File.join(@index, 'generation.json'), '{not json')

    corrupt = call(server, 'lookup', identifier: 'Post').fetch('result')
    expect(corrupt['isError']).to be(true)
    expect(corrupt.dig('_meta', 'error_code')).to eq('corrupt_artifact')
  end

  it 'behaves as a normal server when an index already exists' do
    publish
    server = build(await_index: true)

    expect(initialize_result(server).fetch('instructions')).not_to include('No index was published')
    expect(call(server, 'lookup', identifier: 'Post').dig('result', 'isError')).to be(false)
  end

  describe 'in a fresh linked worktree of an indexed repository' do
    def git(dir, *args)
      output, outcome = Open3.capture2e('git', '-C', dir, *args)
      raise "git #{args.join(' ')} failed: #{output}" unless outcome.success?

      output
    end

    before do
      @main = File.join(@base, 'main')
      @topic = File.join(@base, 'topic')
      git(@base, 'init', '-q', '-b', 'main', @main)
      QuietGit.configure(@main)
      File.write(File.join(@main, 'README.md'), "hi\n")
      git(@main, 'add', 'README.md')
      git(@main, '-c', 'user.name=Spec', '-c', 'user.email=spec@example.com', '-c', 'commit.gpgsign=false',
          'commit', '-q', '-m', 'init')
      git(@main, 'worktree', 'add', '-q', '-b', 'topic', @topic)
      main_index = File.join(@main, 'tmp', 'woods')
      FileUtils.mkdir_p(File.join(main_index, 'payloads'))
      FileUtils.cp_r(fixture_dir, File.join(main_index, 'payloads', 'gen-1'))
      File.write(File.join(main_index, 'generation.json'),
                 JSON.generate(number: 1, token: 't1', updated_at: '2026-11-01T10:00:00Z',
                               payload: 'payloads/gen-1'))
      @index = File.join(@topic, 'tmp', 'woods')
    end

    it 'explains the wait in woods_status with every worktrees mode' do
      server = Dir.chdir(@topic) { build(await_index: true) }

      %w[summary list none].each do |mode|
        result = Dir.chdir(@topic) { call(server, 'woods_status', worktrees: mode).fetch('result') }

        expect(result['isError']).to be(false), mode
        report = JSON.parse(result.dig('content', 0, 'text'))
        expect(report.dig('index', 'state')).to eq('awaiting_index'), mode
        expect(report.dig('identity', 'client_matches')).to be(true), mode
        expect(report.dig('identity', 'warnings')).to eq([]), mode
      end
    end

    it 'refuses a routed root while the index directory does not exist, and routes once it does' do
      server = Dir.chdir(@topic) { build(await_index: true) }

      refused = Dir.chdir(@topic) { call(server, 'woods_status', root: @main) }
      FileUtils.mkdir_p(@index)
      routed = Dir.chdir(@topic) { call(server, 'woods_status', root: @main).fetch('result') }

      expect(refused.dig('result', 'content', 0, 'text')).to include('Routing is unavailable (no_repository)')
      expect(routed['isError']).to be(false), routed.dig('content', 0, 'text')
      expect(JSON.parse(routed.dig('content', 0, 'text'))).to include('ready' => true)
    end
  end

  describe 'the launcher-written .bootstrap.json' do
    def bootstrap(content)
      FileUtils.mkdir_p(@index)
      File.binwrite(File.join(@index, '.bootstrap.json'), content)
      status(build(await_index: true)).dig('index', 'bootstrap')
    end

    it 'reports only started_at, command and state, and only as strings' do
      report = bootstrap(JSON.generate(started_at: '2026-11-15T09:00:00Z', command: 'bin/rails woods:extract',
                                       state: 'running', pid: 4242, token: 'secret', extra: { a: 1 }))
      typed = bootstrap(JSON.generate(started_at: 1_700_000_000, command: ['bin/rails'], state: 'running'))

      expect(report).to eq('readable' => true, 'started_at' => '2026-11-15T09:00:00Z',
                           'command' => 'bin/rails woods:extract', 'state' => 'running')
      expect(typed).to eq('readable' => true, 'state' => 'running')
    end

    it 'caps the read and each value' do
      oversized = bootstrap(JSON.generate(state: 'x' * Woods::MCP::IndexWait::MAX_BOOTSTRAP_BYTES))
      long = bootstrap(JSON.generate(command: 'c' * (Woods::MCP::IndexWait::MAX_BOOTSTRAP_FIELD_CHARS + 50)))

      expect(oversized).to eq('readable' => false, 'reason' => 'too_large')
      expect(long.fetch('command').length).to eq(Woods::MCP::IndexWait::MAX_BOOTSTRAP_FIELD_CHARS)
    end

    it 'reports a malformed file as unreadable' do
      ['{not json', '[1, 2]', ''].each do |content|
        expect(bootstrap(content)).to eq('readable' => false, 'reason' => 'malformed'), content.inspect
      end
    end

    it 'survives invalid UTF-8 bytes and lone surrogate escapes' do
      raw = bootstrap(%({"state": "run\xFFning"}).b)
      escaped = bootstrap('{"state": "run\udc00ning"}')

      expect(raw.fetch('state')).to be_valid_encoding
      expect(escaped.fetch('state')).to be_valid_encoding
    end

    it 'ignores anything that is not a regular file' do
      FileUtils.mkdir_p(File.join(@index, '.bootstrap.json'))

      expect(status(build(await_index: true)).dig('index', 'bootstrap')).to be_nil
    end
  end
end
