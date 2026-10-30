# frozen_string_literal: true

# This contract can run with --options /dev/null and only RSpec.
# The normal repository suite still applies its standard spec_helper hooks.
require 'rspec'
require_relative '../../lib/woods/extraction/extractor_timings'

RSpec.describe Woods::Extraction::ExtractorTimings do
  subject(:timings) { described_class.new }

  describe '#time' do
    it 'returns the block value and records the elapsed seconds under the string key' do
      clock = [10.0, 10.25]
      allow(Process).to receive(:clock_gettime).with(Process::CLOCK_MONOTONIC) { clock.shift }

      expect(timings.time(:models) { :units }).to eq(:units)
      expect(timings.to_h).to eq('models' => 0.25)
    end

    it 'accumulates several calls for the same family, rounded to three decimals' do
      clock = [1.0, 1.0004, 2.0, 2.0004]
      allow(Process).to receive(:clock_gettime).with(Process::CLOCK_MONOTONIC) { clock.shift }

      timings.time(:controllers) { nil }
      timings.time('controllers') { nil }

      expect(timings.to_h).to eq('controllers' => 0.001)
    end

    it 'records the time spent before a raise and re-raises' do
      clock = [5.0, 5.5]
      allow(Process).to receive(:clock_gettime).with(Process::CLOCK_MONOTONIC) { clock.shift }

      expect { timings.time(:routes) { raise ArgumentError, 'boom' } }.to raise_error(ArgumentError, 'boom')
      expect(timings.to_h).to eq('routes' => 0.5)
    end

    it 'is safe to call from several threads at once' do
      threads = Array.new(8) do |index|
        Thread.new { 50.times { timings.time("family_#{index % 2}") { nil } } }
      end
      threads.each(&:join)

      expect(timings.to_h.keys).to contain_exactly('family_0', 'family_1')
    end
  end

  describe '#to_h' do
    it 'is empty before anything was timed' do
      expect(timings).to be_empty
      expect(timings.to_h).to eq({})
    end

    it 'answers a fresh, string-keyed hash sorted by family' do
      clock = [0.0, 1.0, 1.0, 1.5]
      allow(Process).to receive(:clock_gettime).with(Process::CLOCK_MONOTONIC) { clock.shift }
      timings.time(:views) { nil }
      timings.time(:models) { nil }

      first = timings.to_h
      first['models'] = 99.0

      expect(timings.to_h).to eq('models' => 0.5, 'views' => 1.0)
      expect(timings.to_h.keys).to eq(%w[models views])
      expect(timings).not_to be_empty
    end
  end

  describe '.line' do
    it 'is nil when nothing was timed' do
      expect(described_class.line({})).to be_nil
      expect(described_class.line(nil)).to be_nil
    end

    it 'names every family by time when they fit the top count' do
      line = described_class.line({ 'models' => 1.25, 'view_templates' => 12.4, 'routes' => 0.02 })

      expect(line).to eq('Extractor timings (3 families, total 13.7s): view_templates 12.4s, models 1.3s, routes 0.0s')
    end

    it 'keeps the top families and says how many there are in all' do
      timings = (1..10).to_h { |n| ["family_#{n.to_s.rjust(2, '0')}", n.to_f] }

      line = described_class.line(timings, top: 3)

      expect(line).to eq('Extractor timings (top 3 of 10, total 55.0s): ' \
                         'family_10 10.0s, family_09 9.0s, family_08 8.0s')
    end

    it 'breaks ties by family name so the line is stable' do
      line = described_class.line({ 'b' => 1.0, 'a' => 1.0 }, top: 8)

      expect(line).to eq('Extractor timings (2 families, total 2.0s): a 1.0s, b 1.0s')
    end
  end
end
