# frozen_string_literal: true

require 'spec_helper'
require 'json'
require 'tmpdir'
require 'mcp'
require 'woods/mcp/tasks/extension'
require 'woods/mcp/tasks/store'

RSpec.describe Woods::MCP::Tasks::Extension do
  around do |example|
    Dir.mktmpdir { |dir| @index_dir = dir and example.run }
  end

  let(:store) { Woods::MCP::Tasks::Store.new(@index_dir) }

  describe '.client_opted_in?' do
    def meta_with(capabilities)
      { _meta: { 'io.modelcontextprotocol/clientCapabilities' => capabilities } }
    end

    it 'is true when the client declares the tasks extension' do
      params = meta_with({ 'extensions' => { described_class::EXTENSION_ID => {} } })
      expect(described_class.client_opted_in?(params)).to be true
    end

    # The SDK deep-symbolizes incoming params, so the real wire path presents
    # symbol keys even though the spec writes them as strings.
    it 'is true for symbolized keys as the transport actually delivers them' do
      capabilities = { extensions: { described_class::EXTENSION_ID.to_sym => {} } }
      params = { _meta: { described_class::CLIENT_CAPABILITIES_KEY.to_sym => capabilities } }
      expect(described_class.client_opted_in?(params)).to be true
    end

    # "Never return a task to a client that did not declare support." Everything
    # below must stay false — each is a legacy or partially-modern client.
    it 'is false when the client declares other extensions but not tasks' do
      params = meta_with({ 'extensions' => { 'io.modelcontextprotocol/ui' => {} } })
      expect(described_class.client_opted_in?(params)).to be false
    end

    it 'is false when the client declares no extensions' do
      expect(described_class.client_opted_in?(meta_with({}))).to be false
    end

    it 'is false when there is no _meta at all (a legacy client)' do
      expect(described_class.client_opted_in?({ name: 'x' })).to be false
    end

    it 'is false for nil params' do
      expect(described_class.client_opted_in?(nil)).to be false
    end

    it 'is false when _meta is not a hash' do
      expect(described_class.client_opted_in?({ _meta: 'garbage' })).to be false
    end

    it 'is false when the extensions value is not a hash' do
      expect(described_class.client_opted_in?(meta_with({ 'extensions' => 'garbage' }))).to be false
    end
  end

  describe '.create_task_result' do
    it 'is tagged with the task result type' do
      task = store.create!(tool: 'pipeline_extract')
      expect(described_class.create_task_result(task)[:resultType]).to eq('task')
    end

    it 'carries the task handle the client polls with' do
      task = store.create!(tool: 'pipeline_extract')
      expect(described_class.create_task_result(task)[:taskId]).to eq(task.id)
    end

    it 'carries the complete task wire shape' do
      task = store.create!(tool: 'pipeline_extract')
      result = described_class.create_task_result(task)

      expect(result).to include(
        resultType: 'task',
        taskId: task.id,
        status: 'working',
        lastUpdatedAt: task.updated_at
      )
    end
  end

  describe '.install' do
    let(:server) do
      srv = MCP::Server.new(name: 'test', version: '1.0')
      described_class.install(srv, store: store)
      srv
    end

    def call(method, params = {})
      raw = server.handle_json(JSON.generate({ jsonrpc: '2.0', id: 1, method: method, params: params }))
      raw && JSON.parse(raw)
    end

    def task_params(params = {})
      params.merge(
        _meta: {
          'io.modelcontextprotocol/protocolVersion' => MCP::Configuration::LATEST_MODERN_PROTOCOL_VERSION,
          'io.modelcontextprotocol/clientCapabilities' => {
            'extensions' => { described_class::EXTENSION_ID => {} }
          }
        }
      )
    end

    it 'serves tasks/get for a known task' do
      task = store.create!(tool: 'pipeline_extract')
      expect(call('tasks/get', task_params(taskId: task.id)).dig('result', 'status')).to eq('working')
    end

    it 'returns the result once the task completes' do
      task = store.create!(tool: 'pipeline_extract')
      store.complete!(task.id, result: { 'content' => [{ 'type' => 'text', 'text' => 'done' }] })

      got = call('tasks/get', task_params(taskId: task.id)).fetch('result')
      expect(got['status']).to eq('completed')
      expect(got['resultType']).to eq('complete')
      expect(got.dig('result', 'content', 0, 'text')).to eq('done')
    end

    it 'rejects tasks/get when the client did not declare the extension' do
      task = store.create!(tool: 'pipeline_extract')

      error = call('tasks/get', { taskId: task.id })['error']
      expect(error['code']).to eq(MCP::ErrorCodes::MISSING_REQUIRED_CLIENT_CAPABILITY)
      expect(error.dig('data', 'requiredCapabilities', 'extensions', described_class::EXTENSION_ID)).to eq({})
    end

    it 'reports an unknown task as an error rather than a null task' do
      error = call('tasks/get', task_params(taskId: 'a' * 32))['error']
      # JSON-RPC invalid params; the SDK carries the human detail in `data`.
      expect(error['code']).to eq(-32_602)
      expect(error['data']).to match(/Unknown or expired/)
    end

    it 'acknowledges tasks/cancel' do
      task = store.create!(tool: 'pipeline_extract')
      call('tasks/cancel', task_params(taskId: task.id))
      expect(store.get(task.id).status).to eq('cancelled')
    end

    # Cancellation is cooperative and idempotent: cancelling something already
    # finished is not an error, it just does not change the outcome.
    it 'does not error when cancelling an already-completed task' do
      task = store.create!(tool: 'pipeline_extract')
      store.complete!(task.id, result: {})
      expect(call('tasks/cancel', task_params(taskId: task.id))['error']).to be_nil
    end

    # Woods has no task that pauses for input, so `input_required` never occurs
    # and tasks/update has nothing to apply — but the method must exist and
    # answer, because the extension advertises it.
    it 'answers tasks/update' do
      task = store.create!(tool: 'pipeline_extract')
      expect(call('tasks/update', task_params(taskId: task.id, inputResponses: {}))['error']).to be_nil
    end

    it 'advertises the extension in server capabilities' do
      expect(server.capabilities.dig(:extensions, described_class::EXTENSION_ID)).to eq({})
    end

    it 'leaves the rest of the capability set intact' do
      expect(server.capabilities).to have_key(:tools)
    end
  end
end
