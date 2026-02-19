# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'json'
require 'codebase_index/session_tracer/file_store'

RSpec.describe CodebaseIndex::SessionTracer::FileStore do
  let(:base_dir) { Dir.mktmpdir('file_store_test') }
  let(:store) { described_class.new(base_dir: base_dir) }

  after { FileUtils.remove_entry(base_dir) }

  let(:request_data) do
    {
      'session_id' => 'sess1',
      'timestamp' => '2026-02-13T10:30:00Z',
      'method' => 'POST',
      'path' => '/orders',
      'controller' => 'OrdersController',
      'action' => 'create',
      'status' => 302,
      'duration_ms' => 145,
      'format' => 'html'
    }
  end

  describe '#record and #read' do
    it 'records and reads back a single request' do
      store.record('sess1', request_data)
      results = store.read('sess1')

      expect(results.size).to eq(1)
      expect(results[0]['controller']).to eq('OrdersController')
      expect(results[0]['action']).to eq('create')
    end

    it 'appends multiple requests in order' do
      store.record('sess1', request_data.merge('path' => '/orders', 'action' => 'index'))
      store.record('sess1', request_data.merge('path' => '/orders/new', 'action' => 'new'))
      store.record('sess1', request_data.merge('path' => '/orders', 'action' => 'create'))

      results = store.read('sess1')
      expect(results.size).to eq(3)
      expect(results.map { |r| r['action'] }).to eq(%w[index new create])
    end

    it 'isolates sessions from each other' do
      store.record('sess1', request_data.merge('action' => 'create'))
      store.record('sess2', request_data.merge('action' => 'index'))

      expect(store.read('sess1').size).to eq(1)
      expect(store.read('sess2').size).to eq(1)
      expect(store.read('sess1')[0]['action']).to eq('create')
      expect(store.read('sess2')[0]['action']).to eq('index')
    end

    it 'returns empty array for unknown session' do
      expect(store.read('nonexistent')).to eq([])
    end

    it 'sanitizes session IDs with special characters' do
      store.record('sess/../../etc', request_data)
      results = store.read('sess/../../etc')
      expect(results.size).to eq(1)
    end

    it 'skips corrupt lines gracefully' do
      path = File.join(base_dir, 'corrupt.jsonl')
      File.write(path, "{\"valid\":true}\nnot json\n{\"also\":\"valid\"}\n")

      results = store.read('corrupt')
      expect(results.size).to eq(2)
      expect(results[0]['valid']).to be true
      expect(results[1]['also']).to eq('valid')
    end
  end

  describe '#sessions' do
    it 'lists sessions sorted by most recent first' do
      store.record('older', request_data.merge('timestamp' => '2026-02-13T09:00:00Z'))
      sleep 0.01 # Ensure different mtime
      store.record('newer', request_data.merge('timestamp' => '2026-02-13T10:00:00Z'))

      summaries = store.sessions(limit: 10)
      expect(summaries.size).to eq(2)
      expect(summaries[0]['session_id']).to eq('newer')
      expect(summaries[1]['session_id']).to eq('older')
    end

    it 'includes request count and timestamps' do
      store.record('sess1', request_data.merge('timestamp' => '2026-02-13T10:00:00Z'))
      store.record('sess1', request_data.merge('timestamp' => '2026-02-13T10:01:00Z'))

      summaries = store.sessions
      expect(summaries[0]['request_count']).to eq(2)
      expect(summaries[0]['first_request']).to eq('2026-02-13T10:00:00Z')
      expect(summaries[0]['last_request']).to eq('2026-02-13T10:01:00Z')
    end

    it 'respects limit' do
      3.times { |i| store.record("sess#{i}", request_data) }
      expect(store.sessions(limit: 2).size).to eq(2)
    end

    it 'returns empty array when no sessions exist' do
      expect(store.sessions).to eq([])
    end
  end

  describe '#clear' do
    it 'removes a single session' do
      store.record('sess1', request_data)
      store.record('sess2', request_data)

      store.clear('sess1')

      expect(store.read('sess1')).to eq([])
      expect(store.read('sess2').size).to eq(1)
    end

    it 'does not raise for nonexistent session' do
      expect { store.clear('nonexistent') }.not_to raise_error
    end
  end

  describe '#clear_all' do
    it 'removes all sessions' do
      store.record('sess1', request_data)
      store.record('sess2', request_data)

      store.clear_all

      expect(store.sessions).to eq([])
      expect(store.read('sess1')).to eq([])
      expect(store.read('sess2')).to eq([])
    end
  end

  describe 'concurrent writes' do
    it 'handles multiple concurrent writers without data loss' do
      threads = 5.times.map do |i|
        Thread.new do
          store.record('concurrent', request_data.merge('action' => "action_#{i}"))
        end
      end
      threads.each(&:join)

      results = store.read('concurrent')
      expect(results.size).to eq(5)
    end
  end
end
