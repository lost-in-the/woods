# frozen_string_literal: true

require 'spec_helper'
require 'codebase_index/console/adapters/solid_queue_adapter'

RSpec.describe CodebaseIndex::Console::Adapters::SolidQueueAdapter do
  subject(:adapter) { described_class.new }

  describe '.available?' do
    it 'returns true when SolidQueue is defined' do
      stub_const('SolidQueue', Module.new)
      expect(described_class.available?).to be true
    end

    it 'returns false when SolidQueue is not defined' do
      hide_const('SolidQueue')
      expect(described_class.available?).to be false
    end
  end

  describe '#queue_stats' do
    it 'returns a bridge request for queue stats' do
      result = adapter.queue_stats
      expect(result[:tool]).to eq('solid_queue_queue_stats')
      expect(result[:params]).to eq({})
    end
  end

  describe '#recent_failures' do
    it 'returns a bridge request with default limit' do
      result = adapter.recent_failures
      expect(result[:tool]).to eq('solid_queue_recent_failures')
      expect(result[:params][:limit]).to eq(10)
    end

    it 'caps limit at 100' do
      result = adapter.recent_failures(limit: 500)
      expect(result[:params][:limit]).to eq(100)
    end
  end

  describe '#find_job' do
    it 'returns a bridge request for finding a job' do
      result = adapter.find_job(id: 42)
      expect(result[:tool]).to eq('solid_queue_find_job')
      expect(result[:params][:id]).to eq(42)
    end
  end

  describe '#scheduled_jobs' do
    it 'returns a bridge request with default limit' do
      result = adapter.scheduled_jobs
      expect(result[:tool]).to eq('solid_queue_scheduled_jobs')
      expect(result[:params][:limit]).to eq(20)
    end

    it 'caps limit at 100' do
      result = adapter.scheduled_jobs(limit: 500)
      expect(result[:params][:limit]).to eq(100)
    end
  end

  describe '#retry_job' do
    it 'returns a bridge request for retrying a job' do
      result = adapter.retry_job(id: 42)
      expect(result[:tool]).to eq('solid_queue_retry_job')
      expect(result[:params][:id]).to eq(42)
    end
  end
end
