# frozen_string_literal: true

require 'spec_helper'
require 'fileutils'
require 'json'
require 'open3'
require 'timeout'
require 'tmpdir'
require 'mcp'
require 'woods'
require 'woods/mcp/server'
require 'woods/mcp/bootstrapper'
require_relative '../support/quiet_git'

# What an awaiting server does once something appears in the directory it
# waits on: the checkout check a strict launch makes, a damaged marker, and
# capabilities that only a restart can add.
RSpec.describe 'Index MCP server awaiting its first index: guards' do
  let(:fixture_dir) { File.expand_path('../fixtures/woods', __dir__) }

  around do |example|
    Dir.mktmpdir('woods-await-guards') do |directory|
      @base = File.realpath(directory)
      saved = %w[WOODS_MCP_ALLOW_MISMATCH WOODS_MCP_CLIENT_ROOT WOODS_MCP_CLIENT_ROOT_MAP WOODS_RETRIEVAL_MODE
                 WOODS_SNAPSHOTS OPENAI_API_KEY].to_h { |key| [key, ENV.fetch(key, nil)] }
      saved.each_key { |key| ENV.delete(key) }
      begin
        example.run
      ensure
        saved.each { |key, value| ENV[key] = value }
      end
    end
  end

  before do
    Woods.configuration = Woods::Configuration.new
    @main = fake_checkout('main')
    @topic = fake_checkout('topic')
    @index = File.join(@topic, 'tmp', 'woods')
  end

  def fake_checkout(name)
    root = File.join(@base, name)
    FileUtils.mkdir_p(File.join(root, '.git'))
    File.write(File.join(root, '.git', 'HEAD'), "ref: refs/heads/main\n")
    root
  end

  def publish(number, root: @topic, index: @index)
    payload = File.join(index, 'payloads', "gen-#{number}")
    FileUtils.mkdir_p(File.dirname(payload))
    FileUtils.cp_r(fixture_dir, payload)
    manifest = JSON.parse(File.read(File.join(payload, 'manifest.json')))
                   .merge('root' => root, 'woods_version' => Woods::VERSION, 'git_branch' => 'main')
    File.write(File.join(payload, 'manifest.json'), JSON.generate(manifest))
    File.write(File.join(index, 'generation.json'),
               JSON.generate(number: number, token: "t#{number}", updated_at: '2026-11-15T10:00:00Z',
                             payload: "payloads/gen-#{number}"))
  end

  def build(index_dir = @index, **options)
    Dir.chdir(@topic) do
      Woods::MCP::Server.build(index_dir: index_dir, response_format: :json, warmup: false, await_index: true,
                               **options)
    end
  end

  # Wires the collaborators exactly as exe/woods-mcp does.
  def build_like_exe(index_dir, await_index:)
    Dir.chdir(@topic) do
      retriever, state = Woods::MCP::Bootstrapper.build_retriever(index_dir: index_dir, await_index: await_index)
      snapshots = Woods::MCP::Bootstrapper.build_snapshot_store(index_dir, await_index: await_index)
      Woods::MCP::Server.build(index_dir: index_dir, retriever: retriever, bootstrap_state: state,
                               snapshot_store: snapshots, response_format: :json, warmup: false,
                               await_index: await_index)
    end
  end

  def rpc(server, method, params = {})
    Dir.chdir(@topic) do
      JSON.parse(server.handle_json(JSON.generate(jsonrpc: '2.0', id: 1, method: method, params: params)))
    end
  end

  def call(server, name, arguments = {})
    rpc(server, 'tools/call', name: name, arguments: arguments).fetch('result')
  end

  def status(server)
    JSON.parse(call(server, 'woods_status', worktrees: 'none').dig('content', 0, 'text'))
  end

  describe 'the checkout check when a generation lands' do
    def expect_refused(result)
      expect(result['isError']).to be(true)
      expect(result['_meta']).to include('error_code' => 'index_checkout_mismatch', 'retryable' => false)
      expect(result.dig('content', 0, 'text')).to include(@main, @topic, '--allow-mismatch',
                                                          'WOODS_MCP_ALLOW_MISMATCH=1')
    end

    it 'refuses every tool but woods_status, without a retry, when the first generation records another checkout' do
      server = build
      publish(1, root: @main)

      expect_refused(call(server, 'lookup', identifier: 'Post'))
      expect_refused(call(server, 'search', query: 'Post'))
      report = status(server)
      expect(report).to include('ready' => false)
      expect(report.fetch('refusal')).to include('error_code' => 'index_checkout_mismatch')
      expect(report.dig('refusal', 'message')).to include(@main, @topic)
      error = rpc(server, 'resources/read', uri: 'codebase://manifest').fetch('error')
      expect(error.dig('data', 'error_code')).to eq('index_checkout_mismatch')
    end

    it 'serves that generation with a warning under WOODS_MCP_ALLOW_MISMATCH=1' do
      ENV['WOODS_MCP_ALLOW_MISMATCH'] = '1'
      server = build
      publish(1, root: @main)

      expect(call(server, 'lookup', identifier: 'Post')['isError']).to be(false)
      report = status(server)
      expect(report).not_to have_key('refusal')
      expect(report.dig('identity', 'client_matches')).to be(false)
      expect(report.dig('identity', 'mismatch_allowed')).to be(true)
    end

    it 're-checks every later generation, refusing and serving again as the recorded root moves' do
      server = build

      publish(1, root: @topic)
      expect(call(server, 'lookup', identifier: 'Post')['isError']).to be(false)
      publish(2, root: @main)
      expect_refused(call(server, 'lookup', identifier: 'Post'))
      publish(3, root: @topic)
      expect(call(server, 'lookup', identifier: 'Post')['isError']).to be(false)
      expect(status(server)).not_to have_key('refusal')
    end

    it 'reads the generation it judged, even when another is published between the check and the read' do
      server = build
      publish(4, root: @topic)
      published = false
      %i[read pinned].each do |builder|
        allow(Woods::MCP::ServedIdentity).to receive(builder).and_wrap_original do |original, *args, **options|
          original.call(*args, **options).tap do
            publish(5, root: @main) unless published
            published = true
          end
        end
      end

      answer = call(server, 'lookup', identifier: 'Post')

      expect(published).to be(true)
      expect(answer['isError']).to be(false)
      expect(server.instance_variable_get(:@woods_index_reader).loaded_generation).to eq(4)
      expect_refused(call(server, 'lookup', identifier: 'Post'))
    end

    it 'applies to a server that found its index at startup, too' do
      publish(1, root: @topic)
      server = build

      publish(2, root: @main)

      expect_refused(call(server, 'lookup', identifier: 'Post'))
    end
  end

  describe 'the checkout check and reload' do
    def expect_refused_without_manifest(result)
      expect(result['isError']).to be(true)
      expect(result.dig('_meta', 'error_code')).to eq('index_checkout_mismatch')
      expect(result.dig('content', 0, 'text')).not_to include('extracted_at', 'total_units')
    end

    it 'judges the generation reload adopted, not the one checked before it ran' do
      server = build
      publish(8, root: @topic)
      reader = server.instance_variable_get(:@woods_index_reader)
      allow(reader).to receive(:with_exclusive_reload).and_wrap_original do |original, &block|
        publish(9, root: @main)
        original.call(&block)
      end

      expect_refused_without_manifest(call(server, 'reload'))
    end

    it 'judges what a store reloader left published' do
      reloader = lambda do |_reader|
        publish(9, root: @main)
        {}
      end
      server = build(retriever_reloader: reloader)
      publish(8, root: @topic)

      expect_refused_without_manifest(call(server, 'reload'))
    end

    it 'still answers reload with the adopted generation when it records the client checkout' do
      server = build
      publish(8, root: @topic)

      answer = call(server, 'reload')

      expect(answer['isError']).to be(false)
      expect(JSON.parse(answer.dig('content', 0, 'text'))).to include('reloaded' => true)
    end
  end

  describe 'a routed root that resolves to the launch index' do
    def git(dir, *args)
      output, outcome = Open3.capture2e('git', '-C', dir, *args)
      raise "git #{args.join(' ')} failed: #{output}" unless outcome.success?

      output
    end

    def repository(topic_path)
      @main = File.join(@base, 'repo-main')
      git(@base, 'init', '-q', '-b', 'main', @main)
      QuietGit.configure(@main)
      File.write(File.join(@main, 'README.md'), "hi\n")
      git(@main, 'add', 'README.md')
      git(@main, '-c', 'user.name=Spec', '-c', 'user.email=spec@example.com', '-c', 'commit.gpgsign=false',
          'commit', '-q', '-m', 'init')
      @topic = topic_path.call(@main)
      git(@main, 'worktree', 'add', '-q', '-b', 'topic', @topic)
      @topic = File.realpath(@topic)
      @index = File.join(@topic, 'tmp', 'woods')
      publish(1, root: @main, index: File.join(@main, 'tmp', 'woods'))
      publish(1, root: @main)
    end

    {
      'a sibling worktree' => ->(main) { File.join(File.dirname(main), 'repo-topic') },
      'a worktree nested under main' => ->(main) { File.join(main, 'worktrees', 'topic') }
    }.each do |shape, topic_path|
      it "refuses a call routed to the client's own checkout as it refuses it unrouted, in #{shape}" do
        repository(topic_path)
        server = build

        unrouted = call(server, 'lookup', identifier: 'Post')
        routed = call(server, 'lookup', identifier: 'Post', root: @topic)
        report = status_for(server, root: @topic)

        [unrouted, routed].each do |result|
          expect(result['isError']).to be(true)
          expect(result.dig('_meta', 'error_code')).to eq('index_checkout_mismatch')
        end
        expect(report.fetch('refusal')).to include('error_code' => 'index_checkout_mismatch')
      end

      it "still serves a call routed to main from main's own index, in #{shape}" do
        repository(topic_path)
        server = build

        routed = call(server, 'lookup', identifier: 'Post', root: @main)
        report = status_for(server, root: @main)

        expect(routed['isError']).to be(false), routed.dig('content', 0, 'text')
        expect(report).not_to have_key('refusal')
        expect(report.dig('server', 'index_dir')).to eq(File.join(@main, 'tmp', 'woods'))
      end
    end

    def status_for(server, root:)
      JSON.parse(call(server, 'woods_status', worktrees: 'none', root: root).dig('content', 0, 'text'))
    end
  end

  describe 'a generation.json that exists but cannot be used' do
    def expect_corrupt(server)
      answer = call(server, 'lookup', identifier: 'Post')
      expect(answer['isError']).to be(true)
      expect(answer.dig('_meta', 'error_code')).to eq('corrupt_artifact')
      expect(answer.dig('structuredContent', 'data', 'status')).not_to eq('building')
      expect(status(server).dig('index', 'state')).to eq('unusable_publication')
    end

    it 'answers a malformed marker as corrupt, never as building' do
      server = build
      FileUtils.mkdir_p(@index)
      File.write(File.join(@index, 'generation.json'), '{not json')

      expect_corrupt(server)
    end

    it 'answers a payload that escapes the index directory as corrupt' do
      outside = File.join(@base, 'outside')
      FileUtils.cp_r(fixture_dir, outside)
      server = build
      FileUtils.mkdir_p(@index)
      File.write(File.join(@index, 'generation.json'), JSON.generate(number: 1, token: 't', payload: '../outside'))

      expect_corrupt(server)
    end

    it 'answers a payload symlink that leaves the index directory as corrupt' do
      outside = File.join(@base, 'outside')
      FileUtils.cp_r(fixture_dir, outside)
      server = build
      FileUtils.mkdir_p(@index)
      File.symlink(outside, File.join(@index, 'escape'))
      File.write(File.join(@index, 'generation.json'), JSON.generate(number: 1, token: 't', payload: 'escape'))

      expect_corrupt(server)
    end

    it 'answers a payload pointer that names a file as corrupt' do
      server = build
      FileUtils.mkdir_p(File.join(@index, 'payloads'))
      File.write(File.join(@index, 'payloads', 'gen-1'), 'not a directory')
      File.write(File.join(@index, 'generation.json'), JSON.generate(number: 1, token: 't', payload: 'payloads/gen-1'))

      expect_corrupt(server)
    end

    it 'still answers building for a payload that is not written yet' do
      server = build
      FileUtils.mkdir_p(@index)
      File.write(File.join(@index, 'generation.json'), JSON.generate(number: 1, token: 't', payload: 'payloads/g1'))

      expect(call(server, 'lookup', identifier: 'Post').dig('structuredContent', 'data', 'status')).to eq('building')
      expect(status(server).dig('index', 'state')).to eq('awaiting_index')
    end
  end

  describe 'capabilities a restart adds' do
    it 'registers the same tools as a restarted server when the extraction adds no snapshot database' do
      awaiting = build_like_exe(@index, await_index: true)
      publish(1)
      restarted = build_like_exe(@index, await_index: false)

      expect(rpc(awaiting, 'tools/list').dig('result', 'tools'))
        .to eq(rpc(restarted, 'tools/list').dig('result', 'tools'))
    end

    it 'lacks the snapshot tools a restarted server registers once a snapshot database exists, and says so' do
      awaiting = build_like_exe(@index, await_index: true)
      publish(1)
      FileUtils.touch(File.join(@index, 'woods.sqlite3'))
      restarted = build_like_exe(@index, await_index: false)

      snapshot_tools = %w[change_impact list_snapshots snapshot_detail snapshot_diff unit_history]
      expect(restarted.tools.keys).to include(*snapshot_tools)
      expect(awaiting.tools.keys).not_to include(*snapshot_tools)
      expect(status(awaiting).fetch('restart_recommended').map { |entry| entry['feature'] }).to eq(['snapshots'])
    end

    it 'recommends a restart once the extraction leaves a snapshot database or an embedding config' do
      server = build_like_exe(@index, await_index: true)
      publish(1)
      expect(status(server)).not_to have_key('restart_recommended')

      FileUtils.touch(File.join(@index, 'woods.sqlite3'))
      File.write(File.join(@index, 'woods.json'), JSON.generate(schema_version: 1))

      expect(status(server).fetch('restart_recommended')).to contain_exactly(
        { 'feature' => 'snapshots', 'reason' => 'snapshot tools become available after a restart' },
        { 'feature' => 'semantic_retrieval', 'reason' => 'semantic retrieval becomes available after a restart' }
      )
    end

    it 'never creates the index directory for WOODS_SNAPSHOTS=true, and recommends a restart once it exists' do
      ENV['WOODS_SNAPSHOTS'] = 'true'
      server = build_like_exe(@index, await_index: true)

      expect(File.exist?(@index)).to be(false)
      publish(1)
      expect(status(server).fetch('restart_recommended').map { |entry| entry['feature'] }).to include('snapshots')
    end

    it 'does not recommend a restart for an embedding config the restarted server would refuse' do
      server = build_like_exe(@index, await_index: true)
      publish(1)

      ['{not json', JSON.generate(schema_version: 99), JSON.generate(%w[not a hash])].each do |config|
        File.write(File.join(@index, 'woods.json'), config)

        expect(status(server)).not_to have_key('restart_recommended'), config
      end
    end

    it 'recommends nothing for lexical retrieval, which reads the first generation itself' do
      ENV['WOODS_RETRIEVAL_MODE'] = 'lexical'
      server = build_like_exe(@index, await_index: true)
      publish(1)
      File.write(File.join(@index, 'woods.json'), '{}')

      expect(status(server)).not_to have_key('restart_recommended')
    end
  end

  describe 'the launcher-written .bootstrap.json' do
    def bootstrap_report
      status(build).dig('index', 'bootstrap')
    end

    it 'does not follow a symlink, even to a well-formed file outside the index' do
      outside = File.join(@base, 'elsewhere.json')
      File.write(outside, JSON.generate(state: 'running'))
      FileUtils.mkdir_p(@index)
      File.symlink(outside, File.join(@index, '.bootstrap.json'))

      expect(bootstrap_report).to be_nil
    end

    it 'does not block on a FIFO' do
      FileUtils.mkdir_p(@index)
      File.mkfifo(File.join(@index, '.bootstrap.json'))

      report = Timeout.timeout(10) { bootstrap_report }

      expect(report).to be_nil
    end
  end

  it 'creates no index directory for a tasks request' do
    server = build
    meta = { 'io.modelcontextprotocol/protocolVersion' => MCP::Configuration::LATEST_MODERN_PROTOCOL_VERSION,
             'io.modelcontextprotocol/clientCapabilities' => {
               'extensions' => { Woods::MCP::Tasks::Extension::EXTENSION_ID => {} }
             } }

    answers = %w[tasks/get tasks/update tasks/cancel].to_h do |method|
      [method, rpc(server, method, taskId: 'a' * 32, _meta: meta).fetch('error')]
    end

    expect(answers['tasks/get']['data']).to eq('Unknown or expired taskId.')
    expect(answers['tasks/update']['data']).to eq('Unknown or expired taskId.')
    expect(answers['tasks/cancel']['code']).to eq(JsonRpcHandler::ErrorCode::METHOD_NOT_FOUND)
    expect(File.exist?(@index)).to be(false)
  end
end
