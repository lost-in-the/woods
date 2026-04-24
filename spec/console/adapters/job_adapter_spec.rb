# frozen_string_literal: true

require 'spec_helper'
require 'woods/console/adapters/job_adapter'

RSpec.describe Woods::Console::Adapters::JobAdapter do
  let(:concrete) do
    Class.new(described_class) do
      private

      def prefix
        'myq'
      end
    end.new
  end

  describe 'prefix delegation' do
    it 'raises NotImplementedError on the base class' do
      expect { described_class.new.send(:prefix) }.to raise_error(NotImplementedError)
    end
  end

  describe '#queue_stats' do
    it 'builds a {prefix}_queue_stats request with empty params' do
      expect(concrete.queue_stats).to eq(tool: 'myq_queue_stats', params: {})
    end
  end

  describe '#recent_failures' do
    it 'uses default limit of 10' do
      expect(concrete.recent_failures).to eq(tool: 'myq_recent_failures', params: { limit: 10 })
    end

    it 'accepts an explicit limit' do
      expect(concrete.recent_failures(limit: 50)).to eq(tool: 'myq_recent_failures', params: { limit: 50 })
    end

    it 'caps the limit at 100' do
      expect(concrete.recent_failures(limit: 500)).to eq(tool: 'myq_recent_failures', params: { limit: 100 })
    end
  end

  describe '#find_job' do
    it 'passes through the id param' do
      expect(concrete.find_job(id: 'abc123')).to eq(tool: 'myq_find_job', params: { id: 'abc123' })
    end
  end

  describe '#scheduled_jobs' do
    it 'uses default limit of 20' do
      expect(concrete.scheduled_jobs).to eq(tool: 'myq_scheduled_jobs', params: { limit: 20 })
    end

    it 'caps the limit at 100' do
      expect(concrete.scheduled_jobs(limit: 250)).to eq(tool: 'myq_scheduled_jobs', params: { limit: 100 })
    end
  end

  describe '#retry_job' do
    it 'passes through the id param' do
      expect(concrete.retry_job(id: 42)).to eq(tool: 'myq_retry_job', params: { id: 42 })
    end
  end

  describe 'subclass contract' do
    it 'uses the subclass prefix in every request' do
      other = Class.new(described_class) do
        private

        def prefix
          'alt'
        end
      end.new

      expect(other.queue_stats[:tool]).to start_with('alt_')
      expect(other.find_job(id: 1)[:tool]).to start_with('alt_')
    end
  end
end
