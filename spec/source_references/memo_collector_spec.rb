# frozen_string_literal: true

require 'spec_helper'
require 'woods/source_references/memo_collector'

RSpec.describe Woods::SourceReferences::MemoCollector do
  let(:source) { "class Ledger\n  def call = Shipment.new\nend\n" }

  it 'returns the same analysis as the plain collector' do
    expect(described_class.new.call(source)).to eq(Woods::SourceReferences::Collector.new.call(source))
  end

  it 'parses each distinct source once' do
    inner = Woods::SourceReferences::Collector.new
    allow(inner).to receive(:call).and_call_original
    memo = described_class.new(collector: inner)

    first = memo.call(source)
    expect(memo.call(source.dup)).to equal(first)
    memo.call("module Widget; end\n")
    expect(inner).to have_received(:call).twice
  end

  it 'hands out frozen analyses so no consumer can alter another consumer\'s copy' do
    analysis = described_class.new.call(source)
    expect(analysis).to be_frozen
    expect(analysis.fetch('declarations')).to be_frozen
    expect(analysis.fetch('declarations').first).to be_frozen
  end
end
