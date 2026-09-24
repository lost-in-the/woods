# frozen_string_literal: true

require 'spec_helper'
require 'woods/embedding/token_counter'

RSpec.describe Woods::Embedding::TokenCounter do
  subject(:counter) { described_class.new }

  before { described_class.reset_warned! }

  it 'returns zero for nil and empty input' do
    expect(counter.count(nil)).to eq(0)
    expect(counter.count('')).to eq(0)
  end

  it 'uses an explicitly injected local tokenizer' do
    encoded = Struct.new(:ids).new([12, 34, 56])
    tokenizer = double('local tokenizer', encode: encoded)
    local = described_class.new(tokenizer: tokenizer)
    expect(local.count('dense source')).to eq(3)
    expect(local.exact?).to be true
    expect(tokenizer).to have_received(:encode).with('dense source')
  end

  it 'labels the fallback honestly and never loads a tokenizer from an ID' do
    local = described_class.new(chars_per_token: 2.0, tokenizer_id: 'bert-base-uncased')
    expect(local).not_to receive(:require)
    expect(Kernel).to receive(:warn).with(/counts are estimates/).once
    expect(local.count('0123456789')).to eq(5)
    expect(local.exact?).to be false
    local.count('another call')
  end

  it 'deduplicates the estimate warning across concurrent counters' do
    expect(Kernel).to receive(:warn).once
    values = Array.new(4) { Thread.new { described_class.new.count('racing call') } }.map(&:value)
    expect(values).to all(be_a(Integer))
  end
end
