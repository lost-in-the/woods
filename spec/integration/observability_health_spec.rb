# frozen_string_literal: true

require 'spec_helper'
require 'stringio'
require 'json'
require 'codebase_index/observability/health_check'
require 'codebase_index/observability/structured_logger'
require 'codebase_index/observability/instrumentation'
require 'codebase_index/storage/vector_store'
require 'codebase_index/storage/metadata_store'
require 'codebase_index/embedding/provider'

RSpec.describe 'Observability + Health Integration', :integration do
  # ── HealthCheck with real components ────────────────────────────

  describe 'HealthCheck' do
    let(:vector_store) { CodebaseIndex::Storage::VectorStore::InMemory.new }
    let(:metadata_store) { CodebaseIndex::Storage::MetadataStore::SQLite.new(':memory:') }

    let(:embedding_provider) do
      Class.new do
        include CodebaseIndex::Embedding::Provider::Interface

        define_method(:embed) { |_text| [0.1, 0.2, 0.3] }
        define_method(:embed_batch) { |texts| texts.map { |t| embed(t) } }
        define_method(:dimensions) { 3 }
        define_method(:model_name) { 'test' }
      end.new
    end

    it 'reports healthy when all components are configured and working' do
      check = CodebaseIndex::Observability::HealthCheck.new(
        vector_store: vector_store,
        metadata_store: metadata_store,
        embedding_provider: embedding_provider
      )

      status = check.run

      expect(status.healthy?).to be true
      expect(status.components[:vector_store]).to eq(:ok)
      expect(status.components[:metadata_store]).to eq(:ok)
      expect(status.components[:embedding_provider]).to eq(:ok)
    end

    it 'reports healthy when optional components are nil' do
      check = CodebaseIndex::Observability::HealthCheck.new(
        vector_store: vector_store,
        metadata_store: nil,
        embedding_provider: nil
      )

      status = check.run

      expect(status.healthy?).to be true
      expect(status.components[:vector_store]).to eq(:ok)
      expect(status.components[:metadata_store]).to eq(:not_configured)
      expect(status.components[:embedding_provider]).to eq(:not_configured)
    end

    it 'reports unhealthy when a store raises an error' do
      broken_store = Object.new
      def broken_store.count
        raise StandardError, 'connection lost'
      end

      check = CodebaseIndex::Observability::HealthCheck.new(
        vector_store: broken_store,
        metadata_store: metadata_store,
        embedding_provider: embedding_provider
      )

      status = check.run

      expect(status.healthy?).to be false
      expect(status.components[:vector_store]).to eq(:error)
      expect(status.components[:metadata_store]).to eq(:ok)
    end

    it 'reports error for provider that lacks required methods' do
      bad_provider = Object.new

      check = CodebaseIndex::Observability::HealthCheck.new(
        vector_store: vector_store,
        metadata_store: metadata_store,
        embedding_provider: bad_provider
      )

      status = check.run

      expect(status.healthy?).to be false
      expect(status.components[:embedding_provider]).to eq(:error)
    end

    it 'works with populated stores' do
      vector_store.store('User', [0.1, 0.2, 0.3], { type: 'model' })
      metadata_store.store('User', { type: 'model', identifier: 'User', file_path: 'app/models/user.rb' })

      check = CodebaseIndex::Observability::HealthCheck.new(
        vector_store: vector_store,
        metadata_store: metadata_store,
        embedding_provider: embedding_provider
      )

      status = check.run
      expect(status.healthy?).to be true
    end
  end

  # ── StructuredLogger ────────────────────────────────────────────

  describe 'StructuredLogger' do
    let(:output) { StringIO.new }
    let(:logger) { CodebaseIndex::Observability::StructuredLogger.new(output: output) }

    it 'writes JSON log lines' do
      logger.info('extraction.complete', units: 42)

      output.rewind
      line = output.readline
      entry = JSON.parse(line)

      expect(entry['level']).to eq('info')
      expect(entry['event']).to eq('extraction.complete')
      expect(entry['units']).to eq(42)
      expect(entry).to have_key('timestamp')
    end

    it 'supports all log levels' do
      logger.debug('debug.event', data: 'test')
      logger.info('info.event', data: 'test')
      logger.warn('warn.event', data: 'test')
      logger.error('error.event', data: 'test')

      output.rewind
      lines = output.readlines
      levels = lines.map { |l| JSON.parse(l)['level'] }

      expect(levels).to eq(%w[debug info warn error])
    end

    it 'includes timestamps in ISO8601 format' do
      logger.info('test.event')

      output.rewind
      entry = JSON.parse(output.readline)

      expect { Time.parse(entry['timestamp']) }.not_to raise_error
    end

    it 'includes arbitrary structured data' do
      logger.info('embedding.batch', count: 10, duration_ms: 150, model: 'nomic')

      output.rewind
      entry = JSON.parse(output.readline)

      expect(entry['count']).to eq(10)
      expect(entry['duration_ms']).to eq(150)
      expect(entry['model']).to eq('nomic')
    end

    it 'writes one line per log entry' do
      logger.info('event1')
      logger.info('event2')
      logger.info('event3')

      output.rewind
      lines = output.readlines
      expect(lines.size).to eq(3)

      # Each line should be valid JSON
      lines.each do |line|
        expect { JSON.parse(line) }.not_to raise_error
      end
    end
  end

  # ── Instrumentation ─────────────────────────────────────────────

  describe 'Instrumentation' do
    it 'yields the block and returns its value' do
      result = CodebaseIndex::Observability::Instrumentation.instrument('test.event') do
        42
      end

      expect(result).to eq(42)
    end

    it 'passes payload to the block' do
      received_payload = nil
      CodebaseIndex::Observability::Instrumentation.instrument('test.event', units: 10) do |payload|
        received_payload = payload
      end

      expect(received_payload).to eq({ units: 10 })
    end

    it 'returns nil when no block is given and no AS::Notifications' do
      result = CodebaseIndex::Observability::Instrumentation.instrument('test.event')
      expect(result).to be_nil
    end
  end

  # ── Combined: Logger + HealthCheck workflow ─────────────────────

  describe 'Logger + HealthCheck workflow' do
    it 'logs health check results' do
      output = StringIO.new
      logger = CodebaseIndex::Observability::StructuredLogger.new(output: output)

      vector_store = CodebaseIndex::Storage::VectorStore::InMemory.new
      metadata_store = CodebaseIndex::Storage::MetadataStore::SQLite.new(':memory:')

      check = CodebaseIndex::Observability::HealthCheck.new(
        vector_store: vector_store,
        metadata_store: metadata_store
      )

      status = check.run
      logger.info('health.check', healthy: status.healthy?, components: status.components)

      output.rewind
      entry = JSON.parse(output.readline)

      expect(entry['event']).to eq('health.check')
      expect(entry['healthy']).to be true
      expect(entry['components']['vector_store']).to eq('ok')
      expect(entry['components']['metadata_store']).to eq('ok')
    end
  end

  # ── Combined: Instrumentation + Logger ──────────────────────────

  describe 'Instrumentation + Logger workflow' do
    it 'instruments and logs an operation' do
      output = StringIO.new
      logger = CodebaseIndex::Observability::StructuredLogger.new(output: output)

      result = CodebaseIndex::Observability::Instrumentation.instrument('extraction.unit', identifier: 'User') do
        logger.info('extraction.unit.complete', identifier: 'User', tokens: 150)
        'extracted'
      end

      expect(result).to eq('extracted')

      output.rewind
      entry = JSON.parse(output.readline)
      expect(entry['event']).to eq('extraction.unit.complete')
      expect(entry['identifier']).to eq('User')
      expect(entry['tokens']).to eq(150)
    end
  end
end
