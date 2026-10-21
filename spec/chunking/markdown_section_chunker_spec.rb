# frozen_string_literal: true

require 'spec_helper'
require 'woods/extracted_unit'
require 'woods/chunking/markdown_section_chunker'

RSpec.describe Woods::Chunking::MarkdownSectionChunker do
  def unit_for(source)
    Woods::ExtractedUnit.new(type: :doc, identifier: 'docs/ledger.md', file_path: '/app/docs/ledger.md').tap do |unit|
      unit.source_code = source
    end
  end

  def chunk(source, **options)
    described_class.new(unit_for(source), **options).chunk
  end

  let(:source) do
    <<~MARKDOWN
      Intro line.

      # Ledger

      Overview.

      ## Posting

      Post entries.

      ```ruby
      # not a heading
      Ledger.post
      ```

      ## Posting

      Second section with the same title.

      # Closing
    MARKDOWN
  end

  it 'emits one chunk per heading section plus the preamble' do
    chunks = chunk(source)

    expect(chunks.map { |c| c.chunk_type.to_s }).to eq(%w[section_0 section_1 section_2 section_3 section_4])
    expect(chunks.map { |c| c.metadata[:heading] }).to eq([nil, 'Ledger', 'Posting', 'Posting', 'Closing'])
    expect(chunks[2].content).to include('Post entries.', '# not a heading', 'Ledger.post')
    expect(chunks[2].content).not_to include('Second section')
  end

  it 'records the heading path, a unique anchor and the line range' do
    chunks = chunk(source)

    expect(chunks[2].metadata).to eq(heading: 'Posting', level: 2, heading_path: %w[Ledger Posting],
                                     anchor: 'posting', start_line: 7, end_line: 15)
    expect(chunks[3].metadata).to include(anchor: 'posting-1', heading_path: %w[Ledger Posting])
    expect(chunks[4].metadata).to include(heading_path: ['Closing'], level: 1, start_line: 20, end_line: 20)
    expect(chunks[0].metadata).to eq(heading: nil, level: 0, heading_path: [], anchor: nil, start_line: 1,
                                     end_line: 2)
  end

  it 'gives every chunk its own identifier under the parent document' do
    identifiers = chunk(source).map(&:identifier)

    expect(identifiers.uniq.size).to eq(5)
    expect(identifiers).to all(start_with('docs/ledger.md#section_'))
  end

  it 'splits a section over the size cap on line boundaries' do
    body = (1..40).map { |n| "Line #{n} of the shipment manifest." }.join("\n")
    chunks = chunk("# Shipments\n\n#{body}\n", max_chars: 300)

    expect(chunks.size).to be > 1
    expect(chunks.first(2).map { |c| c.chunk_type.to_s }).to eq(%w[section_0_part_0 section_0_part_1])
    expect(chunks.map(&:content)).to all(satisfy { |content| content.length <= 300 })
    expect(chunks.map(&:content).join).to eq("# Shipments\n\n#{body}\n")
    expect(chunks.map { |c| c.metadata[:part] }).to eq((0...chunks.size).to_a)
    expect(chunks.map { |c| c.metadata[:heading] }.uniq).to eq(['Shipments'])
  end

  it 'hard-splits a single line longer than the cap' do
    chunks = chunk("# Blob\n#{'x' * 1000}\n", max_chars: 256)

    expect(chunks.map(&:content)).to all(satisfy { |content| content.length <= 256 })
    expect(chunks.map(&:content).join).to eq("# Blob\n#{'x' * 1000}\n")
  end

  it 'returns a single section for a document without headings and nothing for an empty one' do
    expect(chunk("just text\n").map { |c| c.chunk_type.to_s }).to eq(['section_0'])
    expect(chunk("  \n")).to eq([])
    expect(described_class.new(unit_for(nil)).chunk).to eq([])
  end

  it 'rejects a non-positive cap' do
    expect { chunk('# a', max_chars: 0) }.to raise_error(ArgumentError, /max_chars/)
  end
end
