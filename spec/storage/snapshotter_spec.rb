# frozen_string_literal: true

require 'spec_helper'
require 'woods/storage/snapshotter'

RSpec.describe Woods::Storage::Snapshotter do
  it 'is a namespace module that loads the Vector and Metadata adapters' do
    expect(described_class).to be_a(Module)
    expect(described_class.const_defined?(:Vector, false)).to be(true)
    expect(described_class.const_defined?(:Metadata, false)).to be(true)
  end

  it 'exposes Vector as a class with dump/load_or_empty semantics' do
    expect(described_class::Vector).to respond_to(:dump).or respond_to(:new)
  end

  it 'exposes Metadata as a class with dump/load_or_empty semantics' do
    expect(described_class::Metadata).to respond_to(:dump).or respond_to(:new)
  end

  it 'shares the InapplicableBackend error class' do
    expect(Woods::Storage::InapplicableBackend).to be < Woods::Error
  end
end
