# frozen_string_literal: true

require 'spec_helper'
require 'woods/notion/mappers/shared'

# Direct coverage for rich_text_property. The mapper specs only send short
# strings, so the >2000 truncation branch — a Notion API limit that rejects
# oversized payloads — was untested.
RSpec.describe Woods::Notion::Mappers::Shared do
  # Class.new's block is class_eval'd, so described_class must be captured
  # before the block opens.
  subject(:mapper) do
    shared = described_class
    Class.new { include shared }.new
  end

  it 'wraps short text in a rich_text property' do
    expect(mapper.rich_text_property('users table')).to eq(
      { rich_text: [{ text: { content: 'users table' } }] }
    )
  end

  it 'coerces non-string input through to_s' do
    content = mapper.rich_text_property(nil)[:rich_text].first[:text][:content]

    expect(content).to eq('')
  end

  it 'keeps exactly-2000-char text intact' do
    boundary = 'a' * described_class::MAX_RICH_TEXT_LENGTH
    content = mapper.rich_text_property(boundary)[:rich_text].first[:text][:content]

    expect(content).to eq(boundary)
    expect(content.length).to eq(2000)
  end

  it 'truncates above the API limit and marks the cut with an ellipsis' do
    oversized = 'b' * 2500
    content = mapper.rich_text_property(oversized)[:rich_text].first[:text][:content]

    expect(content.length).to eq(2000)
    expect(content).to end_with('...')
    expect(content).to start_with(oversized[0...1997])
  end

  it 'truncates text one character over the limit' do
    over_by_one = 'c' * (described_class::MAX_RICH_TEXT_LENGTH + 1)
    content = mapper.rich_text_property(over_by_one)[:rich_text].first[:text][:content]

    expect(content.length).to eq(2000)
    expect(content).to end_with('...')
  end
end
