# frozen_string_literal: true

require 'spec_helper'
require 'timeout'
require 'woods/extracted_unit'
require 'woods/ast/parser'
require 'woods/ruby_analyzer/class_analyzer'
require 'woods/chunking/semantic_chunker'
require 'woods/retrieval/source_evidence'

# Each example runs a 1 MB multibyte input through a path that used to do
# O(input) work per definition, slice or concern. The budget is far above the
# linear cost and far below the old quadratic one (13s to minutes).
RSpec.describe 'scan hygiene: offset complexity' do
  megabyte = 1_048_576

  def within_seconds(seconds, &block)
    Timeout.timeout(seconds, &block)
  end

  def nodes(root, type)
    root.find_all(type)
  end

  describe Woods::Ast::Parser do
    let(:definitions) { megabyte / 30 }
    let(:source) do
      "class Widget\n#{(1..definitions).map { |index| "  def ship_#{index}\n    'é'\n  end\n" }.join}end\n"
    end

    it 'gives every definition of a 1 MB file its source span in linear time' do
      defs = within_seconds(20) { nodes(described_class.new.parse(source), :def) }
      lines = source.lines

      expect(defs.size).to eq(definitions)
      [defs.first, defs[definitions / 2], defs.last].each do |node|
        expect(node.source).to eq(lines[(node.line - 1)..(node.end_line - 1)].join)
      end
    end

    it 'keeps parser-gem byte offsets exact for multibyte text on shared and separate lines' do
      parser = described_class.new
      allow(parser).to receive(:prism_available?).and_return(false)
      text = "class Widget\r\n  def a; 'é'; end; def b; 'ü→'; end\r\n\r\n  def self.c\n    'é'\n  end\nend\n"

      spans = parser.parse(text).find_all(:def).map { |node| text.byteslice(node.start_byte...node.end_byte) }
      spans += parser.parse(text).find_all(:defs).map { |node| text.byteslice(node.start_byte...node.end_byte) }

      expect(spans).to eq(["def a; 'é'; end", "def b; 'ü→'; end", "def self.c\n    'é'\n  end"])
    end

    it 'splits the source once per parser-gem parse, however many definitions ask for offsets' do
      parser = described_class.new
      allow(parser).to receive(:prism_available?).and_return(false)
      shared = (1..500).map { |index| "def s#{index}; 'é'; end" }.join('; ')
      text = "class Widget\n#{(1..2_000).map { |index| "  def m#{index}\n    'é'\n  end\n" }.join}#{shared}\nend\n"
      allow(Woods::Ast::LineTable).to receive(:new).and_call_original

      defs = parser.parse(text).find_all(:def)

      expect(Woods::Ast::LineTable).to have_received(:new).once
      expect(defs.map { |node| text.byteslice(node.start_byte...node.end_byte) })
        .to eq((1..2_000).map { |index| "def m#{index}\n    'é'\n  end" } +
               (1..500).map { |index| "def s#{index}; 'é'; end" })
    end
  end

  describe Woods::RubyAnalyzer::ClassAnalyzer do
    it 'gives every class of a 1 MB file its source span in linear time' do
      count = megabyte / 24
      source = (1..count).map { |index| "class Widget#{index}\n  # é\nend\n" }.join

      units = within_seconds(30) { described_class.new.analyze(source: source, file_path: '/app/widgets.rb') }

      expect(units.size).to eq(count)
      expect(units.last.source_code).to eq("class Widget#{count}\n  # é\nend\n")
    end
  end

  describe Woods::Chunking::SemanticChunker do
    let(:content) { "# é shipment ledger line\n" * (megabyte / 25) }

    def unit_with_whole_chunk(content)
      unit = Woods::ExtractedUnit.new(type: :poro, identifier: 'Widget', file_path: 'app/models/widget.rb')
      unit.source_code = content
      location = { file_path: 'app/models/widget.rb', start_byte: 0, end_byte: content.bytesize,
                   start_line: 1, end_line: content.count("\n") }
      unit.chunks = [{ content: content, chunk_type: :whole,
                       metadata: { physical_location: location,
                                   published_location: { start_byte: 0, end_byte: content.bytesize } } }]
      unit
    end

    it 'numbers the lines of every slice of a 1 MB chunk in linear time' do
      unit = unit_with_whole_chunk(content)
      within_seconds(8) { described_class.new(max_chars: 64).enforce_chunk_limits!(unit) }

      expect(unit.chunks.sum { |chunk| chunk[:content].bytesize }).to eq(content.bytesize)
      [unit.chunks.first, unit.chunks[unit.chunks.size / 2], unit.chunks.last].each do |chunk|
        first, last = chunk[:embedding_slice].values_at(:start_byte, :end_byte)
        start_line = 1 + content.byteslice(0...first).count("\n")
        end_line = start_line + content.byteslice(first...last).delete_suffix("\n").count("\n")
        expect(chunk[:metadata][:physical_location]).to include(start_byte: first, end_byte: last,
                                                                start_line: start_line, end_line: end_line)
      end
    end

    it 'fills a large slice from short multibyte lines in linear time' do
      slices = within_seconds(1.5) { described_class.new.send(:slice_by_lines, content, 600_000) }

      expect(slices.join).to eq(content)
      expect(slices.map(&:length)).to eq([600_000, content.length - 600_000])
    end

    it 'cuts a line longer than the regex repeat ceiling at character boundaries' do
      line = "#{'é' * 250_001}\n"

      slices = described_class.new.send(:slice_by_lines, "short\n#{line}", 120_000)

      expect(slices.join).to eq("short\n#{line}")
      expect(slices.map(&:length)).to eq([6, 120_000, 120_000, 10_002])
    end
  end

  describe Woods::Retrieval::SourceEvidence do
    it 'locates every inlined-concern block of a 1 MB unit by byte offset' do
      names = (1..100).map { |index| "Shippable#{index}" }
      filler = "# é ledger\n" * (megabyte / 12 / names.size)
      source = names.map { |name| "#{filler}# │ Included from: #{name} │\n#   def ship; end\n# ─ End #{name} ─\n" }
                    .join
      unit = { 'identifier' => 'Widget', 'type' => 'model', 'source_code' => source,
               'metadata' => { 'inlined_concerns' => names } }

      spans = within_seconds(8) { described_class.new(unit: unit).send(:concern_spans) }

      expect(spans.map(&:name)).to eq(names)
      spans.each do |span|
        text = source.byteslice(span.start_byte...span.end_byte)
        expect(text).to eq("# │ Included from: #{span.name} │\n#   def ship; end\n# ─ End #{span.name} ─")
        expect(span.end_line - span.start_line).to eq(2)
      end
      expect(spans.last.end_line).to eq(source.count("\n"))
    end
  end
end
