# frozen_string_literal: true

require 'spec_helper'
require 'json'
require 'tmpdir'
require 'fileutils'
require 'woods'
require 'woods/dependency_graph'
require 'woods/mcp/server'
require 'woods/operator/pipeline_guard'

# End-to-end: does a long-running pipeline tool actually hand back a durable
# task handle, and does that handle survive the things it exists to survive?
RSpec.describe 'pipeline tools and the Tasks extension' do
  let(:operator) do
    { status_reporter: nil, pipeline_guard: nil, pipeline_lock: nil, error_escalator: nil }
  end

  # A writable copy of the fixture index. The task store lives inside the index
  # directory, so pointing the server at the tracked fixture would have the
  # suite write records into the repo.
  around do |example|
    Dir.mktmpdir do |dir|
      FileUtils.cp_r(File.join(File.expand_path('../../fixtures/woods', __dir__), '.'), dir)
      @index_dir = dir
      begin
        example.run
      ensure
        # The tool answers immediately and finishes on a background thread that
        # releases the pipeline lock from inside this directory. Let it land
        # before mktmpdir removes the ground from under it.
        drain_background_threads
      end
    end
  end

  def drain_background_threads
    (Thread.list - [Thread.current]).each { |t| t.join(2) }
  end

  let(:server) do
    Woods::MCP::Server.build(
      index_dir: @index_dir, response_format: :json, warmup: false, operator: operator
    )
  end

  # The extraction itself is not under test here — the task lifecycle is — and
  # Woods::Extractor needs a booted Rails, so it is stubbed the same way
  # server_spec does it.
  before do
    stub_const('Woods::Extractor', double('ExtractorClass', new: fake_extractor))
    stub_const('Woods::MCP::Server::PIPELINE_LOCK_WAIT', 0)
    config = Woods.configuration || Woods::Configuration.new
    allow(Woods).to receive(:configuration).and_return(config)
    allow(config).to receive(:output_dir).and_return(@index_dir)
  end

  after do
    drain_background_threads
  end

  let(:fake_extractor) { double('Extractor') }

  def call(params, id: 1)
    raw = server.handle_json(
      JSON.generate({ jsonrpc: '2.0', id: id, method: 'tools/call', params: params })
    )
    JSON.parse(raw)
  end

  def rpc(method, params, id: 9)
    JSON.parse(server.handle_json(JSON.generate({ jsonrpc: '2.0', id: id, method: method, params: params })))
  end

  let(:tasks_meta) do
    { '_meta' => tasks_capability_meta }
  end

  let(:tasks_capability_meta) do
    {
      'io.modelcontextprotocol/protocolVersion' => MCP::Configuration::LATEST_MODERN_PROTOCOL_VERSION,
      'io.modelcontextprotocol/clientCapabilities' => {
        'extensions' => { 'io.modelcontextprotocol/tasks' => {} }
      }
    }
  end

  def extract_call(meta = {})
    call({ 'name' => 'pipeline_extract', 'arguments' => {} }.merge(meta))
  end

  def task_params(task_id, extra = {})
    { 'taskId' => task_id, '_meta' => tasks_capability_meta }.merge(extra)
  end

  def settle
    # The tool answers immediately and finishes on a background thread.
    100.times do
      break if yield

      sleep 0.02
    end
  end

  describe 'a client that declared the Tasks extension' do
    before { allow(fake_extractor).to receive(:extract_all).and_return(true) }

    it 'gets a task result rather than a fire-and-forget acknowledgement' do
      expect(extract_call(tasks_meta).dig('result', 'resultType')).to eq('task')
    end

    it 'gets a handle it can poll with' do
      task_id = extract_call(tasks_meta).dig('result', 'taskId')
      expect(rpc('tasks/get', task_params(task_id)).dig('result', 'taskId')).to eq(task_id)
    end

    it 'is told how often to poll' do
      expect(extract_call(tasks_meta).dig('result', 'pollIntervalMs')).to be_positive
    end

    # The completion signal that did not exist before: previously the agent got
    # "started" and had to infer the outcome from pipeline_status.
    it 'sees the task reach completed once the run finishes' do
      task_id = extract_call(tasks_meta).dig('result', 'taskId')
      settle { rpc('tasks/get', task_params(task_id)).dig('result', 'status') == 'completed' }

      expect(rpc('tasks/get', task_params(task_id)).dig('result', 'status')).to eq('completed')
    end
  end

  describe 'cancellation capability audit' do
    it 'does not claim cancellation when blocked work cannot be stopped safely' do
      started = Queue.new
      release = Queue.new
      published = File.join(@index_dir, 'completed-generation.json')
      allow(fake_extractor).to receive(:extract_all) do
        started << true
        release.pop
        File.write(published, '{}')
      end

      task_id = extract_call(tasks_meta).dig('result', 'taskId')
      started.pop
      error = rpc('tasks/cancel', task_params(task_id)).fetch('error')

      probe = Woods::MCP::Server.send(:build_extraction_lock, @index_dir)
      lock_held_while_working = !probe.acquire
      probe.release unless lock_held_while_working
      release << true
      settle { rpc('tasks/get', task_params(task_id)).dig('result', 'status') == 'completed' }

      lock_released_after_completion = false
      after_completion = nil
      20.times do
        after_completion = Woods::MCP::Server.send(:build_extraction_lock, @index_dir)
        lock_released_after_completion = after_completion.acquire
        break if lock_released_after_completion

        sleep 0.02
      end
      after_completion.release if lock_released_after_completion

      aggregate_failures do
        expect(error).to include('code' => -32_601, 'message' => 'Method not found')
        expect(error['data']).to eq('Task cancellation is not supported by Woods.')
        expect(lock_held_while_working).to be true
        expect(lock_released_after_completion).to be true
        expect(File.exist?(published)).to be true
      end
    ensure
      release << true if defined?(release)
    end
  end

  describe 'when the run fails' do
    before do
      allow(Logger).to receive(:new).and_call_original
      allow(Logger).to receive(:new).with($stderr).and_return(double('Logger', error: nil))
      allow(fake_extractor).to receive(:extract_all).and_raise(StandardError, 'disk on fire')
    end

    # Previously this error reached a log the agent cannot read, and the tool
    # had already reported success.
    it 'surfaces the failure through the task instead of only the log' do
      task_id = extract_call(tasks_meta).dig('result', 'taskId')
      settle { rpc('tasks/get', task_params(task_id)).dig('result', 'status') == 'failed' }

      task = rpc('tasks/get', task_params(task_id)).fetch('result')
      expect(task['status']).to eq('failed')
      expect(task.dig('error', 'message')).to include('disk on fire')
      expect(task.dig('error', 'code')).to eq(-32_603)
    end
  end

  describe 'when the run fails with a ScriptError (not a StandardError)' do
    before do
      allow(Logger).to receive(:new).and_call_original
      allow(Logger).to receive(:new).with($stderr).and_return(double('Logger', error: nil))
      # The background thread's runner lazily requires the extractor; a
      # half-typed file there raises SyntaxError, which is NOT a
      # StandardError. Before the fix that unwound the thread past the task
      # bookkeeping entirely, leaving the record "working" forever (until
      # pid-death orphan detection eventually caught it).
      allow(fake_extractor).to receive(:extract_all).and_raise(SyntaxError, 'unexpected end-of-input')
    end

    it 'still fails the task instead of leaving it working forever' do
      task_id = extract_call(tasks_meta).dig('result', 'taskId')
      settle { rpc('tasks/get', task_params(task_id)).dig('result', 'status') == 'failed' }

      task = rpc('tasks/get', task_params(task_id)).fetch('result')
      expect(task['status']).to eq('failed')
      expect(task.dig('error', 'message')).to include('unexpected end-of-input')
    end
  end

  describe 'a client that did not declare the extension' do
    before { allow(fake_extractor).to receive(:extract_all).and_return(true) }

    # Handing a task to a client that cannot poll would have it report a
    # completed run that never happened.
    it 'gets the previous fire-and-forget behaviour unchanged' do
      body = extract_call
      expect(body.dig('result', 'resultType')).to be_nil
      expect(body.dig('result', 'content', 0, 'text')).to include('started')
    end

    it 'creates no task record' do
      extract_call
      expect(Dir.glob(File.join(@index_dir, 'tasks', '*.json'))).to be_empty
    end

    it 'does not create a task for a legacy request that names the extension' do
      legacy_meta = Marshal.load(Marshal.dump(tasks_meta))
      legacy_meta['_meta']['io.modelcontextprotocol/protocolVersion'] = '2025-11-25'

      body = extract_call(legacy_meta)

      expect(body.dig('result', 'resultType')).to be_nil
      expect(Dir.glob(File.join(@index_dir, 'tasks', '*.json'))).to be_empty
    end
  end

  describe 'when opted-in task storage is read-only' do
    it 'starts no record, cooldown, or work when producer identity is unavailable' do
      guard = instance_double(Woods::Operator::PipelineGuard, allow?: true, record!: nil)
      operator[:pipeline_guard] = guard
      allow(fake_extractor).to receive(:extract_all).and_return(true)
      allow_any_instance_of(Woods::MCP::Tasks::Store).to receive(:producer_identity_for).and_return(nil)

      body = extract_call(tasks_meta)

      expect(body.dig('result', '_meta', 'error_code')).to eq('task_store_unavailable')
      expect(Dir.glob(File.join(@index_dir, 'tasks', '*.json'))).to be_empty
      expect(guard).not_to have_received(:record!)
      expect(fake_extractor).not_to have_received(:extract_all)
      in_flight = Woods::MCP::Server.instance_variable_get(:@pipeline_in_flight)
      expect(in_flight).not_to have_key(:extraction)
    end

    it 'fails closed without starting untrackable work' do
      # The read-only index dir is simulated with chmod 0o555, which root
      # ignores — the store stays writable and no refusal is produced.
      skip 'requires non-root: chmod 0o555 does not stop root from writing' if Process.uid.zero?

      allow(fake_extractor).to receive(:extract_all).and_return(true)
      allow(Woods.configuration).to receive(:output_dir).and_return(nil)
      server
      File.chmod(0o555, @index_dir)

      body = extract_call(tasks_meta)

      expect(body.dig('result', 'isError')).to be true
      expect(body.dig('result', '_meta', 'error_code')).to eq('task_store_unavailable')
      expect(fake_extractor).not_to have_received(:extract_all)
    ensure
      File.chmod(0o755, @index_dir) if @index_dir && File.exist?(@index_dir)
    end

    it 'does not consume pipeline cooldown and permits an immediate retry' do
      guard = instance_double(Woods::Operator::PipelineGuard, allow?: true, record!: nil)
      operator[:pipeline_guard] = guard
      allow(fake_extractor).to receive(:extract_all).and_return(true)
      attempts = 0
      original_create = Woods::MCP::Tasks::Store.instance_method(:create!)
      allow_any_instance_of(Woods::MCP::Tasks::Store).to receive(:create!) do |instance, **arguments|
        attempts += 1
        raise Errno::EACCES if attempts == 1

        original_create.bind_call(instance, **arguments)
      end

      first = extract_call(tasks_meta)
      second = extract_call(tasks_meta)

      expect(first.dig('result', '_meta', 'error_code')).to eq('task_store_unavailable')
      expect(second.dig('result', 'resultType')).to eq('task')
      expect(guard).to have_received(:record!).with(:extraction).once
    end
  end

  describe 'durability across processes' do
    before { allow(fake_extractor).to receive(:extract_all).and_return(true) }

    # The disconnect-survival claim: the handle is on disk, so a *different*
    # server object — standing in for a restarted process — can still answer.
    it 'lets a freshly built server answer a handle minted by another' do
      task_id = extract_call(tasks_meta).dig('result', 'taskId')
      settle { rpc('tasks/get', task_params(task_id)).dig('result', 'status') == 'completed' }

      other = Woods::MCP::Server.build(index_dir: @index_dir, warmup: false)
      raw = other.handle_json(
        JSON.generate({ jsonrpc: '2.0', id: 1, method: 'tasks/get', params: task_params(task_id) })
      )
      expect(JSON.parse(raw).dig('result', 'status')).to eq('completed')
    end

    it 'serves tasks/get even on a server built without the operator wiring' do
      lean = Woods::MCP::Server.build(index_dir: @index_dir, warmup: false)
      raw = lean.handle_json(
        JSON.generate({ jsonrpc: '2.0', id: 1, method: 'tasks/get', params: task_params('f' * 32) })
      )
      # Unknown id, but the method itself must be served — a restarted process
      # may come up wired differently and still owes an answer for old handles.
      # The SDK carries the detail in `data` under a generic `message`.
      error = JSON.parse(raw)['error']
      expect(error['code']).to eq(-32_602)
      expect(error['data']).to match(/Unknown or expired/)
    end
  end

  describe 'capability advertisement' do
    it 'names the tasks extension in server/discover' do
      caps = rpc('server/discover', {}).dig('result', 'capabilities')
      expect(caps.dig('extensions', 'io.modelcontextprotocol/tasks')).to eq({})
    end
  end
end
