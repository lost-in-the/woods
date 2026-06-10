# frozen_string_literal: true

require 'spec_helper'
require 'woods'
require 'woods/unblocked/rate_limiter'

RSpec.describe Woods::Unblocked::RateLimiter do
  describe '#track' do
    it 'yields and counts calls under budget' do
      limiter = described_class.new(daily_budget: 2)
      expect(limiter.track { :ok }).to eq(:ok)
      expect(limiter.used).to eq(1)
      expect(limiter.remaining).to eq(1)
    end

    it 'raises BudgetExhaustedError once the budget is spent' do
      limiter = described_class.new(daily_budget: 1)
      limiter.track { :ok }
      expect { limiter.track { :never } }
        .to raise_error(Woods::Unblocked::BudgetExhaustedError)
    end

    it 'raises an error that is a Woods::Error with the budget message' do
      # The exporter and rake task branch on this contract — pin both halves.
      limiter = described_class.new(daily_budget: 1)
      limiter.track { :ok }
      expect { limiter.track { :never } }
        .to raise_error(Woods::Error, /daily budget exhausted/)
    end
  end
end
