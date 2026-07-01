# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'pathname'
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
end
