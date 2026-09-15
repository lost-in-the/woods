# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'woods/watch/boot_snapshot'

RSpec.describe Woods::Watch::BootSnapshot do
  around do |example|
    Dir.mktmpdir('woods_boot_snapshot') do |root|
      @root = root
      example.run
    end
  end

  it 'detects replacements even when the mtime and size are preserved' do
    path = File.join(@root, 'Gemfile.lock')
    File.write(path, 'old')
    snapshot = described_class.new(root: @root)
    time = File.mtime(path)
    replacement = File.join(@root, 'replacement')
    File.write(replacement, 'new')
    File.utime(time, time, replacement)
    File.rename(replacement, path)

    expect(snapshot.covers?(path)).to be(false)
    expect(snapshot.changed_paths).to eq([path])
  end

  it 'detects additions and deletions of boot inputs' do
    original = File.join(@root, 'Gemfile')
    added = File.join(@root, 'Gemfile.lock')
    File.write(original, '# original')
    snapshot = described_class.new(root: @root)
    File.unlink(original)
    File.write(added, '# added')

    expect(snapshot.changed_paths).to contain_exactly(original, added)
    expect(snapshot.covers?(original)).to be(false)
    expect(snapshot.covers?(added)).to be(false)
    expect(described_class.new(root: @root).covers?(original)).to be(true)
  end

  it 'does not treat an unreadable file as proof of absence' do
    snapshot = described_class.new(root: @root)
    allow(File).to receive(:stat).with(File.join(@root, 'Gemfile.lock')).and_raise(Errno::EACCES)

    expect { snapshot.covers?('Gemfile.lock') }.to raise_error(Errno::EACCES)
  end

  it 'covers unchanged inputs and ignores files that do not require a reload' do
    path = File.join(@root, 'Gemfile.lock')
    File.write(path, '# unchanged')
    snapshot = described_class.new(root: @root)
    File.write(File.join(@root, 'README.md'), '# edited')

    expect(snapshot.covers?('Gemfile.lock')).to be(true)
    expect(snapshot.changed_paths).to be_empty
  end
end
