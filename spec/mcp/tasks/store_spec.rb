# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'woods/mcp/tasks/store'

RSpec.describe Woods::MCP::Tasks::Store do
  around do |example|
    Dir.mktmpdir { |dir| @index_dir = dir and example.run }
  end

  let(:store) { described_class.new(@index_dir) }

  describe '#create!' do
    subject(:task) { store.create!(tool: 'pipeline_extract') }

    it 'returns a task in the working state' do
      expect(task.status).to eq('working')
    end

    it 'mints a unique id' do
      expect(task.id).not_to eq(store.create!(tool: 'pipeline_extract').id)
    end

    it 'records the originating tool' do
      expect(task.tool).to eq('pipeline_extract')
    end

    it 'records the owning process so a crash can be detected later' do
      expect(task.pid).to eq(Process.pid)
    end

    # "The task must be durably created before sending the response" — otherwise
    # a client can receive a taskId the server has no record of.
    it 'persists the task before returning' do
      expect(File.exist?(File.join(@index_dir, described_class::DIRNAME, "#{task.id}.json"))).to be true
    end

    it 'writes nothing outside its own subdirectory' do
      task
      expect(Dir.children(@index_dir)).to contain_exactly(described_class::DIRNAME)
    end
  end

  describe '#get' do
    it 'round-trips a task through disk' do
      created = store.create!(tool: 'pipeline_embed')
      reloaded = described_class.new(@index_dir).get(created.id)

      expect(reloaded.id).to eq(created.id)
      expect(reloaded.tool).to eq('pipeline_embed')
      expect(reloaded.status).to eq('working')
    end

    it 'returns nil for an unknown id' do
      expect(store.get('nope')).to be_nil
    end

    # Task ids reach the store from client input, so the lookup must not be
    # able to address anything outside the task directory.
    it 'refuses to traverse out of the task directory' do
      expect(store.get('../../etc/passwd')).to be_nil
    end

    it 'refuses an id containing a separator' do
      expect(store.get('a/b')).to be_nil
    end

    it 'returns nil rather than raising on a corrupt record' do
      task = store.create!(tool: 'pipeline_extract')
      File.write(File.join(@index_dir, described_class::DIRNAME, "#{task.id}.json"), 'not json{')

      expect(store.get(task.id)).to be_nil
    end

    it 'returns nil for syntactically valid records missing required fields' do
      task = store.create!(tool: 'pipeline_extract')
      path = File.join(@index_dir, described_class::DIRNAME, "#{task.id}.json")
      File.write(path, JSON.generate('id' => task.id))

      expect(store.get(task.id)).to be_nil
    end

    it 'returns nil when a record has malformed timestamps' do
      task = store.create!(tool: 'pipeline_extract')
      path = File.join(@index_dir, described_class::DIRNAME, "#{task.id}.json")
      raw = JSON.parse(File.read(path))
      raw['created_at'] = 'not-a-timestamp'
      File.write(path, JSON.generate(raw))

      expect(store.get(task.id)).to be_nil
    end

    it 'returns nil when a record timestamp is not a string' do
      task = store.create!(tool: 'pipeline_extract')
      path = File.join(@index_dir, described_class::DIRNAME, "#{task.id}.json")
      raw = JSON.parse(File.read(path))
      raw['created_at'] = 123
      File.write(path, JSON.generate(raw))

      expect(store.get(task.id)).to be_nil
    end
  end

  describe 'terminal transitions' do
    let(:task) { store.create!(tool: 'pipeline_extract') }

    it 'records a completed result' do
      store.complete!(task.id, result: { 'content' => [{ 'type' => 'text', 'text' => 'done' }] })
      reloaded = store.get(task.id)

      expect(reloaded.status).to eq('completed')
      expect(reloaded.result.dig('content', 0, 'text')).to eq('done')
    end

    it 'records a failure with its message' do
      store.fail!(task.id, message: 'boom')
      expect(store.get(task.id).error['message']).to eq('boom')
    end

    it 'records a JSON-RPC error code for failures' do
      store.fail!(task.id, message: 'boom')
      expect(store.get(task.id).error['code']).to eq(described_class::JSON_RPC_INTERNAL_ERROR)
    end

    it 'marks a failure as failed' do
      store.fail!(task.id, message: 'boom')
      expect(store.get(task.id).status).to eq('failed')
    end

    # Terminal states never regress after a late producer update.
    it 'refuses to move a task out of a terminal state' do
      store.complete!(task.id, result: { 'ok' => true })
      store.fail!(task.id, message: 'too late')

      expect(store.get(task.id).status).to eq('completed')
    end

    # Returning the record rather than a bare boolean means a caller that wants
    # the new state does not have to re-read it.
    it 'returns the updated record when the transition applies' do
      expect(store.complete!(task.id, result: {})).to have_attributes(status: 'completed')
    end

    it 'returns nil when the transition is refused' do
      store.complete!(task.id, result: {})
      expect(store.fail!(task.id, message: 'late')).to be_nil
    end
  end

  describe '#note_progress!' do
    it 'attaches a human-readable status message without leaving working' do
      task = store.create!(tool: 'pipeline_extract')
      store.note_progress!(task.id, 'extracting models')
      reloaded = store.get(task.id)

      expect(reloaded.status).to eq('working')
      expect(reloaded.status_message).to eq('extracting models')
    end
  end

  # The crash-resilience claim. Today a pipeline_extract thread dies with its
  # process and the agent is left polling a run that no longer exists; a task
  # whose owner is gone must resolve to a terminal state instead of `working`
  # forever.
  describe 'orphan detection' do
    let(:task) { store.create!(tool: 'pipeline_extract') }

    before do
      raw = JSON.parse(File.read(File.join(@index_dir, described_class::DIRNAME, "#{task.id}.json")))
      raw['pid'] = 2**30 # a pid that cannot be running
      File.write(File.join(@index_dir, described_class::DIRNAME, "#{task.id}.json"), JSON.generate(raw))
    end

    it 'reports a working task whose process is gone as failed' do
      expect(store.get(task.id).status).to eq('failed')
    end

    it 'uses stable JSON-RPC error metadata when the producer process died' do
      expect(store.get(task.id).error).to include('code' => described_class::JSON_RPC_INTERNAL_ERROR)
    end

    it 'explains why it failed' do
      expect(store.get(task.id).error['message']).to match(/did not survive/i)
    end

    it 'persists the transition so the answer is stable across readers' do
      store.get(task.id)
      expect(described_class.new(@index_dir).get(task.id).status).to eq('failed')
    end

    it 'leaves a task owned by a live process alone' do
      live = store.create!(tool: 'pipeline_embed')
      expect(store.get(live.id).status).to eq('working')
    end

    # A task that already finished carries no live pid and must not be
    # retroactively reinterpreted as a crash.
    it 'does not touch an already-terminal task' do
      done = store.create!(tool: 'pipeline_embed')
      store.complete!(done.id, result: {})
      path = File.join(@index_dir, described_class::DIRNAME, "#{done.id}.json")
      raw = JSON.parse(File.read(path))
      raw['pid'] = 2**30
      File.write(path, JSON.generate(raw))

      expect(store.get(done.id).status).to eq('completed')
    end
  end

  describe 'expiry' do
    it 'drops a record older than its ttl' do
      task = store.create!(tool: 'pipeline_extract', ttl_ms: 0)
      store.complete!(task.id, result: {})

      expect(store.get(task.id)).to be_nil
    end

    it 'sweeps expired records off disk when a new task is created' do
      old = store.create!(tool: 'pipeline_extract', ttl_ms: 0)
      store.complete!(old.id, result: {})
      store.create!(tool: 'pipeline_embed')

      expect(File.exist?(File.join(@index_dir, described_class::DIRNAME, "#{old.id}.json"))).to be false
    end

    # An unfinished task must outlive its ttl rather than vanish mid-run and
    # strand a client that is still polling it.
    it 'keeps a still-working task past its ttl' do
      task = store.create!(tool: 'pipeline_extract', ttl_ms: 0)
      expect(store.get(task.id)).not_to be_nil
    end

    it 'measures terminal task ttl from creation rather than the last update' do
      task = store.create!(tool: 'pipeline_extract', ttl_ms: 10_000)
      path = File.join(@index_dir, described_class::DIRNAME, "#{task.id}.json")
      raw = JSON.parse(File.read(path))
      raw['created_at'] = (Time.now.utc - 60).iso8601
      File.write(path, JSON.generate(raw))

      store.complete!(task.id, result: {})

      expect(store.get(task.id)).to be_nil
    end
  end

  describe 'concurrent polling' do
    it 'returns the same durable result to concurrent readers' do
      task = store.create!(tool: 'pipeline_extract')
      store.complete!(task.id, result: { 'ok' => true })

      results = 12.times.map { Thread.new { described_class.new(@index_dir).get(task.id)&.to_h } }.map(&:value)

      expect(results).to all(eq(results.first))
      expect(results.first[:result]).to eq('ok' => true)
    end
  end

  describe 'the wire shape' do
    it 'matches the CreateTaskResult fields the extension advertises' do
      task = store.create!(tool: 'pipeline_extract', ttl_ms: 1000, poll_interval_ms: 250)
      expect(task.to_h).to include(
        taskId: task.id,
        status: 'working',
        ttlMs: 1000,
        pollIntervalMs: 250,
        createdAt: task.created_at,
        lastUpdatedAt: task.updated_at
      )
    end

    it 'omits result and error while still working' do
      expect(store.create!(tool: 'pipeline_extract').to_h.keys).not_to include(:result, :error)
    end

    it 'carries the result once completed' do
      task = store.create!(tool: 'pipeline_extract')
      store.complete!(task.id, result: { 'ok' => true })
      expect(store.get(task.id).to_h[:result]).to eq({ 'ok' => true })
    end
  end
end
