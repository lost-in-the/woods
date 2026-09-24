# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'timeout'
require 'woods/source_inputs/private_key'
require 'woods/source_inputs/stable_reader'

RSpec.describe Woods::SourceInputs::StableReader do
  around do |example|
    Dir.mktmpdir('woods-source-read') do |root|
      @root = root
      @key = Woods::SourceInputs::PrivateKey.new(output_dir: File.join(root, 'index'), create: true)
      @path = File.join(root, 'app/services/pay.rb')
      FileUtils.mkdir_p(File.dirname(@path))
      File.binwrite(@path, "# encoding: UTF-8\r\nclass Pay; VALUE = '£'; end\r\n")
      example.run
    end
  end

  def identity(bytes = File.binread(@path))
    OpenSSL::HMAC.hexdigest('SHA256', @key.bytes, bytes)
  end

  def reader
    described_class.new(root: @root, key: @key)
  end

  def read(path = @path, expected: identity, **limits)
    reader.read(path, identity: expected, **limits)
  end

  it 'returns exact binary bytes and only their keyed captured identity' do
    result = read
    expect(result).to eq('path' => 'app/services/pay.rb', 'source' => File.binread(@path), 'identity' => identity)
    expect(result['source'].encoding).to eq(Encoding::BINARY)
    expect(result.values).to all(be_frozen)
    expect(result['identity']).not_to eq(Digest::SHA256.hexdigest(result['source']))
  end

  it 'rejects content changed since capture even with the same size and mtime' do
    expected = identity
    timestamp = File.mtime(@path)
    File.binwrite(@path, File.binread(@path).sub('Pay', 'Tax'))
    File.utime(timestamp, timestamp, @path)
    expect { read(expected: expected) }.to raise_error(described_class::Error, 'source_snapshot_mismatch')
  end

  it 'rejects traversal and paths outside the root' do
    [File.join(@root, '..', 'foreign.rb'), "#{@root}-other/app.rb"].each do |path|
      expect { read(path) }.to raise_error(described_class::Error, 'source_outside_root')
    end
  end

  it 'accepts a captured internal file symlink and rejects an external one' do
    link = File.join(@root, 'app/services/link.rb')
    File.symlink(@path, link)
    expect(read(link)['source']).to eq(File.binread(@path))
    Dir.mktmpdir('woods-source-external') do |outside|
      foreign = File.join(outside, 'foreign.rb')
      File.write(foreign, 'private source')
      File.unlink(link)
      File.symlink(foreign, link)
      expect { read(link) }.to raise_error(described_class::Error, 'source_outside_root')
    end
  end

  it 'refuses nonregular files without blocking' do
    File.unlink(@path)
    File.mkfifo(@path)
    Timeout.timeout(1) do
      expect { read(expected: '0' * 64) }.to raise_error(described_class::Error, 'nonregular_source')
    end
  end

  it 'refuses oversized input and exceeded time budgets' do
    expect { read(max_bytes: 2) }.to raise_error(described_class::Error, 'source_read_byte_budget')
    allow(Process).to receive(:clock_gettime).with(Process::CLOCK_MONOTONIC).and_return(10.0, 12.0)
    expect { read(max_seconds: 1) }.to raise_error(described_class::Error, 'source_read_time_budget')
  end

  it 'validates finite positive read limits' do
    [0, -1, Float::INFINITY, Float::NAN, '1'].each do |limit|
      expect { read(max_bytes: limit) }.to raise_error(ArgumentError)
      expect { read(max_seconds: limit) }.to raise_error(ArgumentError)
    end
  end

  it 'rejects replacement of the descriptor path during reading' do
    expected = identity
    original = File.method(:open)
    allow(File).to receive(:open).and_wrap_original do |_method, path, *args, &block|
      next original.call(path, *args, &block) unless path == @path

      original.call(path, *args) do |file|
        allow(file).to receive(:read).and_wrap_original do |read_method, *read_args|
          bytes = read_method.call(*read_args)
          File.rename(@path, "#{@path}.old") if File.exist?(@path) && !File.exist?("#{@path}.old")
          File.binwrite(@path, 'replacement')
          bytes
        end
        block.call(file)
      end
    end
    expect { read(expected: expected) }.to raise_error(described_class::Error, 'source_changed_during_read')
  end

  it 'rejects a final symlink swapped in before opening with NOFOLLOW' do
    expected = identity
    foreign = File.join(@root, 'app/services/foreign.rb')
    File.binwrite(foreign, 'unrelated')
    original = File.method(:open)
    allow(File).to receive(:open).and_wrap_original do |_method, path, *args, &block|
      if path == @path
        File.unlink(path)
        File.symlink(foreign, path)
      end
      original.call(path, *args, &block)
    end
    expect { read(expected: expected) }.to raise_error(described_class::Error)
  end

  it 'rejects a changed original symlink target before consuming bytes' do
    expected = identity
    link = File.join(@root, 'app/services/link.rb')
    File.symlink(@path, link)
    foreign = File.join(@root, 'app/services/foreign.rb')
    File.binwrite(foreign, 'unrelated')
    original = File.method(:open)
    allow(File).to receive(:open).and_wrap_original do |_method, path, *args, &block|
      if path == @path
        File.unlink(link)
        File.symlink(foreign, link)
      end
      original.call(path, *args, &block)
    end
    expect { read(link, expected: expected) }.to raise_error(described_class::Error, 'source_changed_during_read')
  end
end
