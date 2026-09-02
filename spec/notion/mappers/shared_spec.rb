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

  # EXP-2. Notion's 2000 limit is UTF-16 code units, not Ruby characters. An
  # astral character costs two units, so text that passed the char-count check
  # shipped a payload up to twice the limit and 400'd on every run.
  describe 'non-BMP input' do
    def utf16_units(content)
      content.encode('UTF-16LE').bytesize / 2
    end

    it 'keeps 2000 astral characters under the UTF-16 limit' do
      content = mapper.rich_text_property("\u{1F600}" * 2000)[:rich_text].first[:text][:content]

      expect(utf16_units(content)).to be <= described_class::MAX_RICH_TEXT_LENGTH
    end

    it 'keeps a truncated astral string under the UTF-16 limit' do
      content = mapper.rich_text_property("\u{1F600}" * 2500)[:rich_text].first[:text][:content]

      expect(utf16_units(content)).to be <= described_class::MAX_RICH_TEXT_LENGTH
      expect(content).to end_with('...')
    end

    it 'never splits a surrogate pair' do
      content = mapper.rich_text_property("\u{1F600}" * 2500)[:rich_text].first[:text][:content]

      expect(content).to eq(content.scrub)
      expect(content.delete('.')).to eq("\u{1F600}" * content.delete('.').length)
    end

    it 'leaves a mixed string that fits alone' do
      text = "café \u{1F600}"

      expect(mapper.rich_text_property(text)[:rich_text].first[:text][:content]).to eq(text)
    end
  end
end
