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

  # The policy ignores a generic config helper, but the daemon restarts for
  # one it loaded at boot; without a fingerprint a supervisor restart would
  # not reconcile it and the daemon would exit 75 over the same file forever.
  it 'fingerprints config Ruby helpers the policy ignores, so a boot can cover them (F3)' do
    helper = File.join(@root, 'config', 'time_zone.rb')
    FileUtils.mkdir_p(File.dirname(helper))
    File.write(helper, "Rails.application.config.time_zone = 'UTC'\n")
    snapshot = described_class.new(root: @root)

    expect(snapshot.covers?('config/time_zone.rb')).to be(true)
    File.write(helper, "Rails.application.config.time_zone = 'Hawaii'\n")
    expect(snapshot.covers?('config/time_zone.rb')).to be(false)
    expect(snapshot.changed_paths).to eq([helper])
  end

  # `db:prepare` dumping an unchanged schema, or a stash round trip, writes
  # the bytes the boot already read under a new inode and timestamps.
  {
    'a restart trigger' => 'db/schema.rb',
    'an initializer' => 'config/initializers/widget.rb',
    'a config Ruby helper' => 'config/time_zone.rb'
  }.each do |kind, relative|
    it "covers #{kind} rewritten with the bytes the boot read" do
      path = File.join(@root, relative)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "# boot bytes\n")
      snapshot = described_class.new(root: @root)
      snapshot.boot_finished!
      File.unlink(path)
      File.write(path, "# boot bytes\n")
      File.utime(Time.now + 5, Time.now + 5, path)

      expect(snapshot.covers?(relative)).to be(true)
      expect(snapshot.changed_paths).to be_empty
    end
  end

  it 'never covers by bytes an input that changed and was restored before the boot finished' do
    path = File.join(@root, 'config/initializers/widget.rb')
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "# boot bytes\n")
    snapshot = described_class.new(root: @root)
    File.write(path, "# read by the boot\n")
    File.write(path, "# boot bytes\n")
    File.utime(Time.now + 5, Time.now + 5, path)
    snapshot.boot_finished!

    expect(snapshot.covers?(path)).to be(false)
    expect(snapshot.changed_paths).to eq([path])
  end

  it 'does not cover by bytes before the boot is known to have finished' do
    path = File.join(@root, 'db/schema.rb')
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "# boot bytes\n")
    snapshot = described_class.new(root: @root)
    File.unlink(path)
    File.write(path, "# boot bytes\n")

    expect(snapshot.covers?(path)).to be(false)
  end

  it 'still reports a reload input rewritten with the same bytes' do
    path = File.join(@root, 'app/models/widget.rb')
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "class Widget; end\n")
    snapshot = described_class.new(root: @root)
    snapshot.boot_finished!
    File.unlink(path)
    File.write(path, "class Widget; end\n")

    expect(snapshot.changed_paths).to eq([path])
  end

  it 'reports a boot input created after the boot even when another one holds the same bytes' do
    File.write(File.join(@root, 'Gemfile'), "source 'https://rubygems.org'\n")
    snapshot = described_class.new(root: @root)
    created = File.join(@root, 'Gemfile.lock')
    File.write(created, "source 'https://rubygems.org'\n")

    expect(snapshot.covers?(created)).to be(false)
    expect(snapshot.changed_paths).to eq([created])
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
