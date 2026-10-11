# frozen_string_literal: true

require 'spec_helper'
require 'woods/source_references/runtime_lookup'

RSpec.describe Woods::SourceReferences::RuntimeLookup do
  before do
    stub_const('LookupShipments', Module.new)
    stub_const('LookupShipments::SummaryView', Class.new)
    stub_const('LookupShipments::Quote', Class.new)
    stub_const('LookupLedger', Class.new)
  end

  let(:nesting) { %w[LookupShipments::SummaryView LookupShipments] }

  def ancestor_reads(lookup)
    reads = 0
    allow(lookup).to receive(:reflect).and_wrap_original do |original, scope, method, *args|
      reads += 1 if method == :ancestors && scope.equal?(LookupShipments::SummaryView)
      original.call(scope, method, *args)
    end
    yield
    reads
  end

  context 'when memoized for one reference pass' do
    subject(:lookup) { described_class.new(memoize: true) }

    it 'reads the ancestors of a lexical scope once however many constants it resolves' do
      reads = ancestor_reads(lookup) do
        %w[Quote LookupLedger LookupMissing Quote].each { |name| lookup.call(name, nesting: nesting) }
      end
      expect(reads).to eq(1)
    end

    it 'returns the same resolution as an unmemoized lookup, for hits and misses' do
      plain = described_class.new
      [['Quote', nesting], ['LookupLedger', nesting], ['LookupMissing', nesting], ['Quote', []],
       ['::LookupShipments::Quote', nesting], ['Quote', %w[LookupUnloaded]]].each do |name, scopes|
        2.times { expect(lookup.call(name, nesting: scopes)).to eq(plain.call(name, nesting: scopes)) }
      end
    end

    it 'keeps private access separate from public access to the same name' do
      LookupShipments.send(:private_constant, :Quote)
      expect(lookup.call('::LookupShipments::Quote')).to include(reason: 'private_constant')
      expect(lookup.call('::LookupShipments::Quote', allow_private: true)).to include(status: :resolved)
    end

    it 'returns frozen results that one caller cannot change for the next' do
      expect(lookup.call('Quote', nesting: nesting)).to be_frozen
    end
  end

  context 'when not memoized' do
    subject(:lookup) { described_class.new }

    it 'reads the ancestors of a lexical scope again for every lookup' do
      reads = ancestor_reads(lookup) do
        %w[Quote LookupLedger].each { |name| lookup.call(name, nesting: nesting) }
      end
      expect(reads).to eq(2)
    end

    it 'sees a constant defined between two lookups' do
      expect(lookup.call('LookupLater')).to include(status: :missing)
      stub_const('LookupLater', Class.new)
      expect(lookup.call('LookupLater')).to include(status: :resolved, target: 'LookupLater')
    end
  end
end
