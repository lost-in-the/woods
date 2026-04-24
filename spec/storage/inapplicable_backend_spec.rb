# frozen_string_literal: true

require 'spec_helper'
require 'woods/storage/inapplicable_backend'

RSpec.describe Woods::Storage::InapplicableBackend do
  it 'inherits from Woods::Error' do
    expect(described_class.ancestors).to include(Woods::Error)
  end

  it 'is a StandardError subclass (so consumers can rescue with bare rescue fall-through)' do
    expect(described_class.ancestors).to include(StandardError)
  end

  it 'carries a custom message through the Error chain' do
    err = described_class.new('persistent backends manage their own durability')
    expect(err.message).to eq('persistent backends manage their own durability')
    expect(err).to be_a(Woods::Error)
  end

  it 'can be rescued separately from a generic Woods::Error' do
    raised = nil
    begin
      raise described_class, 'cannot snapshot pgvector'
    rescue described_class => e
      raised = e
    end
    expect(raised.message).to eq('cannot snapshot pgvector')
  end
end
