# frozen_string_literal: true

require 'spec_helper'
require 'woods/extractor'
require 'woods/source_inputs/scopes'

RSpec.describe Woods::SourceInputs::Scopes do
  before { Woods.configuration = Woods::Configuration.new }

  describe '#for_path' do
    it 'matches each path against the dispatch rules once, answering the same each time' do
      scopes = described_class.new
      first = scopes.for_path('app/services/pay.rb')
      matched = scopes.rule_scopes('app/services/pay.rb')

      expect(scopes.for_path('app/services/pay.rb')).to eq(first)
      expect(first).to include('file:services', 'runtime')
      expect(scopes.rule_scopes('app/services/pay.rb')).to equal(matched)
      expect(matched).to be_frozen
    end
  end

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

  describe '#matching_key' do
    it 'differs for every extraction-shaping configuration a matcher can read' do
      keys = { documentation_paths: %w[notes/**/*.md], documentation_exclude: %w[docs/private/**],
               config_file_paths: %w[settings/*.yml], graphql_document_paths: %w[client/**/*.graphql],
               javascript_paths: %w[client/**/*.js], test_support_paths: %w[test/helpers/**/*.rb],
               external_table_consumers_path: 'config/consumers.yml', rake_task_paths: %w[ops/*.rake],
               event_paths: %w[app lib], unclaimed_ruby_paths: %w[engines/**/*.rb] }
      default = described_class.new.matching_key

      keys.each do |key, value|
        Woods.configuration = Woods::Configuration.new
        Woods.configuration.public_send(:"#{key}=", value)
        expect(described_class.new.matching_key).not_to eq(default), "#{key} is not in the matching key"
      end
    end

    it 'reclassifies a path after documentation paths change in the same process' do
      scopes = described_class.new
      expect(scopes.for_path('notes/guide.md')).not_to include('file:docs')

      Woods.configuration.documentation_paths = %w[notes/**/*.md]
      expect(described_class.new.for_path('notes/guide.md')).to include('file:docs')

      Woods.configuration.documentation_paths = Woods::Configuration::DEFAULT_DOCUMENTATION_PATHS
      expect(described_class.new.for_path('notes/guide.md')).not_to include('file:docs')
    end
  end

  describe '#for_path' do
    it 'scopes a lib/ file to the events re-run when lib is an event path' do
      Woods.configuration.event_paths = %w[app lib]

      expect(described_class.new.for_path('lib/ledger/bus.rb')).to include('whole:events')
    end
  end
end
