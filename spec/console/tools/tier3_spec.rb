# frozen_string_literal: true

require 'spec_helper'
require 'codebase_index/console/tools/tier3'

RSpec.describe CodebaseIndex::Console::Tools::Tier3 do
  describe '.console_slow_endpoints' do
    it 'builds a slow_endpoints request with defaults' do
      result = described_class.console_slow_endpoints
      expect(result[:tool]).to eq('slow_endpoints')
      expect(result[:params][:limit]).to eq(10)
      expect(result[:params][:period]).to eq('1h')
    end

    it 'caps limit at 100' do
      result = described_class.console_slow_endpoints(limit: 500)
      expect(result[:params][:limit]).to eq(100)
    end

    it 'accepts custom period' do
      result = described_class.console_slow_endpoints(period: '24h')
      expect(result[:params][:period]).to eq('24h')
    end
  end

  describe '.console_error_rates' do
    it 'builds an error_rates request with defaults' do
      result = described_class.console_error_rates
      expect(result[:tool]).to eq('error_rates')
      expect(result[:params][:period]).to eq('1h')
    end

    it 'includes controller filter' do
      result = described_class.console_error_rates(controller: 'UsersController')
      expect(result[:params][:controller]).to eq('UsersController')
    end
  end

  describe '.console_throughput' do
    it 'builds a throughput request with defaults' do
      result = described_class.console_throughput
      expect(result[:tool]).to eq('throughput')
      expect(result[:params][:period]).to eq('1h')
      expect(result[:params][:interval]).to eq('5m')
    end

    it 'accepts custom parameters' do
      result = described_class.console_throughput(period: '24h', interval: '1h')
      expect(result[:params][:period]).to eq('24h')
      expect(result[:params][:interval]).to eq('1h')
    end
  end

  describe '.console_job_queues' do
    it 'builds a job_queues request' do
      result = described_class.console_job_queues
      expect(result[:tool]).to eq('job_queues')
      expect(result[:params]).to eq({})
    end

    it 'includes queue filter' do
      result = described_class.console_job_queues(queue: 'default')
      expect(result[:params][:queue]).to eq('default')
    end
  end

  describe '.console_job_failures' do
    it 'builds a job_failures request with defaults' do
      result = described_class.console_job_failures
      expect(result[:tool]).to eq('job_failures')
      expect(result[:params][:limit]).to eq(10)
    end

    it 'caps limit at 100' do
      result = described_class.console_job_failures(limit: 500)
      expect(result[:params][:limit]).to eq(100)
    end

    it 'includes queue filter' do
      result = described_class.console_job_failures(queue: 'mailers', limit: 5)
      expect(result[:params][:queue]).to eq('mailers')
    end
  end

  describe '.console_job_find' do
    it 'builds a job_find request' do
      result = described_class.console_job_find(job_id: 'abc-123')
      expect(result[:tool]).to eq('job_find')
      expect(result[:params][:job_id]).to eq('abc-123')
    end

    it 'includes retry flag with confirmation' do
      result = described_class.console_job_find(job_id: 'abc-123', retry_job: true)
      expect(result[:params][:retry]).to be true
      expect(result[:requires_confirmation]).to be true
    end

    it 'does not set confirmation when retry is false' do
      result = described_class.console_job_find(job_id: 'abc-123', retry_job: false)
      expect(result[:params][:retry]).to be false
      expect(result).not_to have_key(:requires_confirmation)
    end

    it 'does not set confirmation when retry is not provided' do
      result = described_class.console_job_find(job_id: 'abc-123')
      expect(result).not_to have_key(:requires_confirmation)
    end
  end

  describe '.console_job_schedule' do
    it 'builds a job_schedule request' do
      result = described_class.console_job_schedule
      expect(result[:tool]).to eq('job_schedule')
      expect(result[:params][:limit]).to eq(20)
    end

    it 'caps limit at 100' do
      result = described_class.console_job_schedule(limit: 500)
      expect(result[:params][:limit]).to eq(100)
    end
  end

  describe '.console_redis_info' do
    it 'builds a redis_info request' do
      result = described_class.console_redis_info
      expect(result[:tool]).to eq('redis_info')
      expect(result[:params]).to eq({})
    end

    it 'includes section filter' do
      result = described_class.console_redis_info(section: 'memory')
      expect(result[:params][:section]).to eq('memory')
    end
  end

  describe '.console_cache_stats' do
    it 'builds a cache_stats request' do
      result = described_class.console_cache_stats
      expect(result[:tool]).to eq('cache_stats')
      expect(result[:params]).to eq({})
    end

    it 'includes namespace filter' do
      result = described_class.console_cache_stats(namespace: 'views')
      expect(result[:params][:namespace]).to eq('views')
    end
  end

  describe '.console_channel_status' do
    it 'builds a channel_status request' do
      result = described_class.console_channel_status
      expect(result[:tool]).to eq('channel_status')
      expect(result[:params]).to eq({})
    end

    it 'includes channel filter' do
      result = described_class.console_channel_status(channel: 'ChatChannel')
      expect(result[:params][:channel]).to eq('ChatChannel')
    end
  end
end
