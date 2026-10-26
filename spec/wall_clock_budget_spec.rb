# frozen_string_literal: true

require 'spec_helper'
require 'yaml'

RSpec.describe WallClockBudget do
  include described_class

  around do |example|
    original = ENV.fetch('WOODS_RUN_PERF_SPECS', nil)
    example.run
  ensure
    original.nil? ? ENV.delete('WOODS_RUN_PERF_SPECS') : ENV['WOODS_RUN_PERF_SPECS'] = original
  end

  context 'without WOODS_RUN_PERF_SPECS' do
    before { ENV.delete('WOODS_RUN_PERF_SPECS') }

    it 'does not enforce budgets' do
      expect(described_class).not_to be_enforced
    end

    it 'runs the block and passes when it overruns the budget' do
      ran = false

      expect do
        within_budget(0.0) do
          ran = true
          sleep 0.01
        end
      end.to output(/exceeded.*enforced only with WOODS_RUN_PERF_SPECS/).to_stderr

      expect(ran).to be(true)
    end

    it 'stays quiet when the block is within the budget' do
      expect { within_budget(60) { :fast } }.not_to output.to_stderr
    end
  end

  context 'with WOODS_RUN_PERF_SPECS' do
    before { ENV['WOODS_RUN_PERF_SPECS'] = '1' }

    it 'enforces budgets' do
      expect(described_class).to be_enforced
    end

    it 'fails when the block overruns the budget' do
      expect { within_budget(0.0) { sleep 0.01 } }.to raise_error(RSpec::Expectations::ExpectationNotMetError)
    end

    it 'passes when the block is within the budget' do
      expect { within_budget(60) { :fast } }.not_to raise_error
    end
  end

  describe 'the performance workflow' do
    let(:workflow) { YAML.load_file(File.expand_path('../.github/workflows/perf.yml', __dir__)) }
    let(:steps) { workflow.dig('jobs', 'perf', 'steps') }

    it 'enforces budgets for the whole job' do
      expect(workflow.dig('jobs', 'perf', 'env', 'WOODS_RUN_PERF_SPECS')).to eq('1')
    end

    it 'runs every spec file that includes WallClockBudget' do
      step = steps.find { |candidate| candidate['run'].to_s.include?('WallClockBudget') }

      expect(step).not_to be_nil
      expect(step['run']).to match(/rspec/)
    end
  end
end
