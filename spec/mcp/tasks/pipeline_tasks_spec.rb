# frozen_string_literal: true

require 'spec_helper'
require 'json'
require 'tmpdir'
require 'fileutils'
require 'woods'
require 'woods/dependency_graph'
require 'woods/mcp/server'

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
    allow(Woods.configuration).to receive(:output_dir).and_return(@index_dir)
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
    20.times do
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
