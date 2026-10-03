# frozen_string_literal: true

require 'spec_helper'
require 'woods/markdown/line_scan'

RSpec.describe Woods::Markdown::LineScan do
  def scan(source)
    described_class.call(source)
  end

  describe 'headings' do
    it 'records ATX headings with level, text and line' do
      result = scan("# Ledger\n\ntext\n\n## Posting entries ##\n###### Deep\n")

      expect(result.headings).to eq([
                                      { level: 1, text: 'Ledger', line: 1 },
                                      { level: 2, text: 'Posting entries', line: 5 },
                                      { level: 6, text: 'Deep', line: 6 }
                                    ])
    end

    it 'keeps a trailing hash that is part of the text' do
      expect(scan("# C#\n").headings.first[:text]).to eq('C#')
    end

    it 'rejects seven hashes, a missing space and a four-space indent' do
      expect(scan("####### seven\n#nospace\n    # indented\n").headings).to eq([])
    end

    it 'records setext headings under a paragraph line' do
      result = scan("Shipment guide\n==============\n\nRouting\n-------\n")

      expect(result.headings).to eq([
                                      { level: 1, text: 'Shipment guide', line: 1 },
                                      { level: 2, text: 'Routing', line: 4 }
                                    ])
    end

    it 'does not read a thematic break after a blank line as a heading' do
      expect(scan("text\n\n---\n").headings).to eq([])
    end

    it 'ignores headings inside fences' do
      expect(scan("```\n# not a heading\n```\n# real\n").headings).to eq([{ level: 1, text: 'real', line: 4 }])
    end
  end

  describe 'front matter' do
    it 'records top-level scalar keys and the line range' do
      result = scan("---\ntitle: Widget setup\nowner: \"platform\"\nnested:\n  child: 1\n---\n# Body\n")

      expect(result.front_matter).to eq([
                                          { key: 'title', value: 'Widget setup', line: 2 },
                                          { key: 'owner', value: 'platform', line: 3 },
                                          { key: 'nested', value: '', line: 4 }
                                        ])
      expect(result.front_matter_lines).to eq(1..6)
      expect(result.headings).to eq([{ level: 1, text: 'Body', line: 7 }])
    end

    it 'treats an unterminated opening rule as body text' do
      result = scan("---\ntitle: x\n# Heading\n")

      expect(result.front_matter).to eq([])
      expect(result.front_matter_lines).to be_nil
      expect(result.headings.map { |heading| heading[:text] }).to eq(['Heading'])
    end
  end

  describe 'code' do
    it 'records inline spans with their line' do
      result = scan("Use `Widget::Importer` then ``rake `quoted` task``.\nplain\n`Ledger`\n")

      expect(result.code).to eq([
                                  { text: 'Widget::Importer', line: 1, fence: false },
                                  { text: 'rake `quoted` task', line: 1, fence: false },
                                  { text: 'Ledger', line: 3, fence: false }
                                ])
    end

    it 'leaves an unmatched backtick run as text' do
      expect(scan("a ` b `` c\n").code).to eq([])
    end

    it 'records fence body lines and closes on a long enough fence' do
      result = scan("````ruby\nWidget.sync\n```\nLedger.post\n````\nafter `Shipment`\n")

      expect(result.code).to eq([
                                  { text: 'Widget.sync', line: 2, fence: true },
                                  { text: '```', line: 3, fence: true },
                                  { text: 'Ledger.post', line: 4, fence: true },
                                  { text: 'Shipment', line: 6, fence: false }
                                ])
    end

    it 'supports tilde fences and an unterminated fence' do
      expect(scan("~~~\nWidget\n").code).to eq([{ text: 'Widget', line: 2, fence: true }])
    end

    it 'does not open a backtick fence whose info string holds a backtick' do
      expect(scan("``` a`b\n# Heading\n").headings.size).to eq(1)
    end
  end

  describe 'links' do
    it 'records inline, angle-bracket and reference targets' do
      source = "See [setup](SETUP.md#install \"t\") and ![img](<img/a b.png>).\n\n[ref]: ../README.md\n"

      expect(scan(source).links).to eq([
                                         { target: 'SETUP.md#install', line: 1 },
                                         { target: 'img/a b.png', line: 1 },
                                         { target: '../README.md', line: 3 }
                                       ])
    end

    it 'ignores links inside fences and empty targets' do
      expect(scan("```\n[a](b.md)\n```\n[c]()\n").links).to eq([])
    end
  end

  it 'counts words outside front matter' do
    expect(scan("---\ntitle: x\n---\n# One two\n\nthree  four\n").word_count).to eq(5)
  end

  it 'handles CRLF line endings and invalid bytes' do
    result = scan("# Title\r\n\r\n`Widget`\xFF\r\n".dup.force_encoding(Encoding::UTF_8))

    expect(result.headings).to eq([{ level: 1, text: 'Title', line: 1 }])
    expect(result.code.first[:text]).to eq('Widget')
  end

  it 'reports the line count' do
    expect(scan("a\nb\nc").line_count).to eq(3)
  end
end
