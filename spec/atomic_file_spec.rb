# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'pathname'
require 'json'
require 'woods/atomic_file'

RSpec.describe Woods::AtomicFile do
  around do |example|
    Dir.mktmpdir do |dir|
      @dir = dir
      example.run
    end
  end

  describe '.write' do
    it 'writes content to the path' do
      path = File.join(@dir, 'note.md')
      described_class.write(path, 'hello')
      expect(File.read(path)).to eq('hello')
    end

    it 'creates missing parent directories' do
      path = File.join(@dir, 'a', 'b', 'c.md')
      described_class.write(path, 'x')
      expect(File.read(path)).to eq('x')
    end

    it 'overwrites an existing file' do
      path = File.join(@dir, 'note.md')
      File.write(path, 'old')
      described_class.write(path, 'new')
      expect(File.read(path)).to eq('new')
    end

    it 'accepts a Pathname' do
      path = Pathname(File.join(@dir, 'p.md'))
      described_class.write(path, 'y')
      expect(File.read(path)).to eq('y')
    end

    it 'leaves no temp files behind on success' do
      described_class.write(File.join(@dir, 'note.md'), 'data')
      leftovers = Dir.children(@dir).reject { |f| f == 'note.md' }
      expect(leftovers).to be_empty
    end

    it 'cleans up the temp file and re-raises if the rename fails, leaving the original intact' do
      path = File.join(@dir, 'note.md')
      File.write(path, 'original')
      allow(File).to receive(:rename).and_raise(Errno::EACCES)

      expect { described_class.write(path, 'new') }.to raise_error(Errno::EACCES)
      expect(File.read(path)).to eq('original')
      leftovers = Dir.children(@dir).reject { |f| f == 'note.md' }
      expect(leftovers).to be_empty
    end
  end

  # The reason .read exists at all.
  #
  # .write goes through binmode, so bytes land verbatim — but a plain
  # File.read tags the result with the process's *default external encoding*,
  # and a container with no locale set (LANG=C, the default in a plain Docker
  # image, which is exactly where the watch daemon is documented to run) makes
  # that US-ASCII. Any byte above 0x7F then raises on the first JSON.parse.
  #
  # Not hypothetical: the daemon writes status reasons containing em dashes, so
  # one ordinary lock contention under LANG=C broke `woods:watch_status`, the
  # hook sync's daemon-deference check and the `woods_status` tool — and
  # Status#read rescued JSON::ParserError and SystemCallError, neither of which
  # an Encoding::InvalidByteSequenceError is, so it raised straight out.
  describe '.read' do
    it 'round-trips non-ASCII content whatever the default external encoding is' do
      path = File.join(@dir, 'status.json')
      content = JSON.generate('reason' => 'lock held — retrying on the next event')
      described_class.write(path, content)

      original = Encoding.default_external
      begin
        # -W0: Ruby warns when the default external encoding is reassigned.
        $VERBOSE = nil
        Encoding.default_external = Encoding::US_ASCII

        expect { JSON.parse(File.read(path)) }.to raise_error(EncodingError)
        expect(JSON.parse(described_class.read(path))['reason']).to include('—')
      ensure
        Encoding.default_external = original
        $VERBOSE = false
      end
    end
  end
end
