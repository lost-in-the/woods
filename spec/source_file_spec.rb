# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'pathname'
require 'woods/source_file'

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

  describe '.readlines' do
    it 'returns valid UTF-8 lines under a US-ASCII default external encoding' do
      path = write_source("# Widget — ledger\nclass Widget; end\n")

      lines = with_posix_default_external { described_class.readlines(path) }

      expect(lines).to eq(["# Widget — ledger\n", "class Widget; end\n"])
      expect(lines).to all(be_valid_encoding)
    end
  end
end
