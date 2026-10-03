# frozen_string_literal: true

require 'spec_helper'
require 'woods/extractor'
require 'woods/source_inputs/scopes'

RSpec.describe Woods::SourceInputs::Scopes do
  before { Woods.configuration = Woods::Configuration.new }

  describe '#fingerprint' do
    it 'is stable across a rule reset for the same configuration' do
      before_reset = described_class.new.fingerprint
      Woods::PathDispatcher.reset!

      expect(described_class.new.fingerprint).to eq(before_reset)
    end

    it 'changes when event_paths changes' do
      default = described_class.new.fingerprint
      Woods.configuration.event_paths = %w[app lib]

      expect(described_class.new.fingerprint).not_to eq(default)
    end

    it 'matches for equal event_paths set on separate configuration objects' do
      Woods.configuration.event_paths = %w[app lib]
      first = described_class.new.fingerprint
      Woods.configuration = Woods::Configuration.new
      Woods.configuration.event_paths = %w[app lib]

      expect(described_class.new.fingerprint).to eq(first)
    end
  end

  describe '#for_path' do
    it 'scopes a lib/ file to the events re-run when lib is an event path' do
      Woods.configuration.event_paths = %w[app lib]

      expect(described_class.new.for_path('lib/ledger/bus.rb')).to include('whole:events')
    end
  end
end
