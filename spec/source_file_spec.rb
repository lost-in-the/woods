# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'pathname'
require 'woods/source_file'
require 'woods/source_references/memo_collector'

RSpec.describe Woods::SourceFile do
  around do |example|
    Dir.mktmpdir do |dir|
      @dir = dir
      example.run
    end
  end

  def write_source(content)
    path = File.join(@dir, 'widget.rb')
    File.binwrite(path, content)
    path
  end

  describe '.read' do
    it 'returns multibyte source as valid UTF-8 under a US-ASCII default external encoding' do
      path = write_source("# Widget — ledger entry\nclass Widget; end\n")

      source = with_posix_default_external { described_class.read(path) }

      expect(source.encoding).to eq(Encoding::UTF_8)
      expect(source).to be_valid_encoding
      expect(source).to match(/class Widget/)
      expect(source).to include('—')
    end

    it 'accepts a Pathname' do
      path = Pathname.new(write_source("class Widget; end\n"))

      expect(described_class.read(path)).to eq("class Widget; end\n")
    end

    it 'scrubs bytes that are not valid UTF-8 instead of returning a broken string' do
      path = write_source("# caf\xE9\nclass Widget; end\n".b)

      source = with_posix_default_external { described_class.read(path) }

      expect(source).to be_valid_encoding
      expect(source).to eq("# caf�\nclass Widget; end\n")
    end

    it 'raises when the file is missing, like File.read' do
      expect { described_class.read(File.join(@dir, 'missing.rb')) }.to raise_error(Errno::ENOENT)
    end
  end

  # The source-reference pass hands MemoCollector the file's raw bytes; the
  # PORO sweep hands it a SourceFile read. Both must hit one cache entry.
  describe 'with the run-scoped source-reference parse cache' do
    it 'shares one parse between a SourceFile read and the raw bytes of the same file' do
      path = write_source("# Ledger — book\nclass Ledger\n  ENTRY = Shipment\nend\n")
      parser = Woods::SourceReferences::Collector.new
      allow(parser).to receive(:call).and_call_original
      memo = Woods::SourceReferences::MemoCollector.new(collector: parser)

      from_reader = with_posix_default_external { memo.call(described_class.read(path)) }
      from_bytes = memo.call(File.binread(path))

      expect(from_bytes).to equal(from_reader)
      expect(parser).to have_received(:call).once
    end
  end

  describe '.readlines' do
    it 'returns valid UTF-8 lines under a US-ASCII default external encoding' do
      path = write_source("# Widget — ledger\nclass Widget; end\n")

      lines = with_posix_default_external { described_class.readlines(path) }

      expect(lines).to eq(["# Widget — ledger\n", "class Widget; end\n"])
      expect(lines).to all(be_valid_encoding)
    end
  end
end
