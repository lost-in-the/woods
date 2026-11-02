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

  it 'keeps each thread\'s analysis whole when several parse through one instance (WDS-100)' do
    # Big enough that the thread scheduler switches mid-parse.
    body = Array.new(400) { |m| "  def step#{m} = Dep#{m}.new\n" }.join
    sources = Array.new(24) { |i| "class Model#{i}\n#{body}end\n" }
    expected = sources.map { |src| Woods::SourceReferences::Collector.new.call(src) }
    memo = described_class.new

    per_thread = Array.new(8) do |t|
      Thread.new { sources.rotate(t * 3).map { |src| memo.call(src) } }
    end.map(&:value)

    per_thread.each_with_index do |results, t|
      expect(results).to eq(expected.rotate(t * 3))
    end
  end
end
