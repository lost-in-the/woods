# frozen_string_literal: true

require 'spec_helper'
require 'fileutils'
require 'json'
require 'open3'
require 'timeout'
require 'tmpdir'

# The packaged launcher, over stdio, in a fresh checkout with no index:
# `woods-mcp-start --checkout --await-index` answers the handshake, then
# `building`, then the index published while it runs.
RSpec.describe 'woods-mcp-start --checkout --await-index over stdio' do
  let(:gem_root) { File.expand_path('../..', __dir__) }
  let(:fixture_dir) { File.expand_path('../fixtures/woods', __dir__) }

  around do |example|
    Dir.mktmpdir('woods-await-cli') do |directory|
      @checkout = File.join(File.realpath(directory), 'fresh-worktree')
      FileUtils.mkdir_p(File.join(@checkout, '.git'))
      File.write(File.join(@checkout, '.git', 'HEAD'), "ref: refs/heads/main\n")
      @index = File.join(@checkout, 'tmp', 'woods')
      example.run
    end
  end

  # One stdio session through the packaged launcher.
  def start(retrieval_mode)
    env = { 'BUNDLE_GEMFILE' => File.join(gem_root, 'Gemfile'), 'WOODS_DIR' => nil, 'WOODS_OUTPUT' => nil,
            'WOODS_RETRIEVAL_MODE' => retrieval_mode, 'WOODS_REQUIRE_INDEX' => nil, 'WOODS_SNAPSHOTS' => nil,
            'MCP_PROTOCOL_VERSION' => nil, 'WOODS_NO_UPDATE_CHECK' => '1', 'OPENAI_API_KEY' => nil,
            'OLLAMA_BASE_URL' => 'http://127.0.0.1:0', 'WOODS_MCP_AWAIT_INDEX' => nil, 'WOODS_MCP_CHECKOUT' => nil }
    command = ['bundle', 'exec', 'ruby', File.join(gem_root, 'exe', 'woods-mcp-start'), '--checkout', '--await-index']
    @stdin, @stdout, @stderr, @wait = Open3.popen3(env, *command, chdir: @checkout)
    @errors = Thread.new { @stderr.read }
    @id = 0
  end

  # Sends one request and reads its one-line response.
  def request(method, params = {})
    @id += 1
    @stdin.puts(JSON.generate(jsonrpc: '2.0', id: @id, method: method, params: params))
    @stdin.flush
    line = Timeout.timeout(60) { @stdout.gets }
    raise "no response to #{method}; stderr: #{stop}" unless line

    JSON.parse(line)
  end

  def call(name, arguments = {})
    request('tools/call', name: name, arguments: arguments).fetch('result')
  end

  # @return [String] stderr
  def stop
    @stdin.close unless @stdin.closed?
    Process.kill('TERM', @wait.pid) unless @wait.join(10)
    @wait.join(10)
    @errors.value.force_encoding(Encoding::UTF_8).scrub
  rescue Errno::ESRCH
    @errors.value.force_encoding(Encoding::UTF_8).scrub
  end

  def publish
    payload = File.join(@index, 'payloads', 'gen-1')
    FileUtils.mkdir_p(File.dirname(payload))
    FileUtils.cp_r(fixture_dir, payload)
    File.write(File.join(@index, 'generation.json'),
               JSON.generate(number: 1, token: 't1', updated_at: '2026-11-15T10:00:00Z', payload: 'payloads/gen-1'))
  end

  { 'semantic' => nil, 'lexical' => 'lexical' }.each do |label, mode|
    it "serves the index published after the handshake, in #{label} retrieval mode" do
      start(mode)
      begin
        init = request('initialize', protocolVersion: '2025-06-18', capabilities: {},
                                     clientInfo: { name: 'await-cli', version: '1' })
        expect(init.dig('result', 'instructions')).to include("No index was published in #{@index}")

        waiting = call('lookup', identifier: 'Post')
        expect(waiting['isError']).to be(false)
        expect(waiting.dig('structuredContent', 'data', 'status')).to eq('building')
        expect(JSON.parse(call('woods_status').dig('content', 0, 'text')).dig('index', 'state'))
          .to eq('awaiting_index')

        publish

        found = call('lookup', identifier: 'Post')
        expect(found['isError']).to be(false)
        expect(found.dig('content', 0, 'text')).to include('Post')
        if mode == 'lexical'
          retrieved = call('codebase_retrieve', query: 'Post')
          expect(retrieved['isError']).to be(false), retrieved.dig('content', 0, 'text')
          expect(retrieved.dig('content', 0, 'text')).to include('Post')
        end
      ensure
        errors = stop
      end
      expect(errors).not_to include('Error', 'Traceback')
      expect(File.exist?(File.join(@checkout, 'tmp', 'woods', 'tasks'))).to be(false)
    end
  end
end
