# frozen_string_literal: true

require 'spec_helper'
require 'woods/console/adapters/job_adapter'

RSpec.describe Woods::Console::Adapters::JobAdapter do
  subject(:adapter) { test_subclass.new }

  let(:test_subclass) do
    Class.new(described_class) do
      private

      def prefix
        'test_queue'
      end
    end
  end

  describe '#prefix' do
    it 'raises NotImplementedError on the base class' do
      expect { described_class.new.send(:prefix) }
        .to raise_error(NotImplementedError, /JobAdapter#prefix must be implemented/)
    end
  end

  describe '#queue_stats' do
    it 'builds a bridge request using the subclass prefix' do
      expect(adapter.queue_stats).to eq(tool: 'test_queue_queue_stats', params: {})
    end
  end

  describe '#recent_failures' do
    it 'defaults limit to 10' do
      expect(adapter.recent_failures).to eq(
        tool: 'test_queue_recent_failures',
        params: { limit: 10 }
      )
    end

    it 'passes through limits below the cap' do
      expect(adapter.recent_failures(limit: 25)[:params][:limit]).to eq(25)
    end

    it 'caps limits above 100' do
      expect(adapter.recent_failures(limit: 500)[:params][:limit]).to eq(100)
    end

    it 'accepts limit exactly equal to the cap' do
      expect(adapter.recent_failures(limit: 100)[:params][:limit]).to eq(100)
    end

    # These pin current behaviour: the cap is one-sided (`[limit, 100].min`)
    # and does not clamp at the low end. If that changes to clamp at >= 1,
    # update these expectations.
    it 'forwards limit: 0 without clamping' do
      expect(adapter.recent_failures(limit: 0)[:params][:limit]).to eq(0)
    end

    it 'forwards negative limits without clamping' do
      expect(adapter.recent_failures(limit: -5)[:params][:limit]).to eq(-5)
    end
  end

  describe '#scheduled_jobs' do
    it 'defaults limit to 20' do
      expect(adapter.scheduled_jobs).to eq(
        tool: 'test_queue_scheduled_jobs',
        params: { limit: 20 }
      )
    end

    it 'passes through limits below the cap' do
      expect(adapter.scheduled_jobs(limit: 50)[:params][:limit]).to eq(50)
    end

    it 'caps limits above 100' do
      expect(adapter.scheduled_jobs(limit: 9_999)[:params][:limit]).to eq(100)
    end
  end

  describe '#find_job' do
    it 'forwards the id without capping or transformation' do
      expect(adapter.find_job(id: 'abc-123')).to eq(
        tool: 'test_queue_find_job',
        params: { id: 'abc-123' }
      )
    end

    it 'accepts integer ids' do
      expect(adapter.find_job(id: 42)[:params][:id]).to eq(42)
    end

    it 'compacts a nil id out of params' do
      expect(adapter.find_job(id: nil)).to eq(
        tool: 'test_queue_find_job',
        params: {}
      )
    end
  end

  describe '#retry_job' do
    it 'forwards the id without capping or transformation' do
      expect(adapter.retry_job(id: 'abc-123')).to eq(
        tool: 'test_queue_retry_job',
        params: { id: 'abc-123' }
      )
    end

    it 'compacts a nil id out of params' do
      expect(adapter.retry_job(id: nil)).to eq(
        tool: 'test_queue_retry_job',
        params: {}
      )
    end
  end

  describe 'request envelope shape' do
    it 'every builder returns { tool: String, params: Hash }' do
      builders = {
        queue_stats: -> { adapter.queue_stats },
        recent_failures: -> { adapter.recent_failures },
        scheduled_jobs: -> { adapter.scheduled_jobs },
        find_job: -> { adapter.find_job(id: 1) },
        retry_job: -> { adapter.retry_job(id: 1) }
      }

      aggregate_failures do
        builders.each do |name, call|
          request = call.call
          expect(request).to be_a(Hash), "#{name} returned #{request.class}"
          expect(request[:tool]).to be_a(String), "#{name} :tool was #{request[:tool].inspect}"
          expect(request[:params]).to be_a(Hash), "#{name} :params was #{request[:params].inspect}"
        end
      end
    end
  end
end
