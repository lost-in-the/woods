# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'woods/impact/artifacts'

RSpec.describe Woods::Impact::Artifacts do
  around do |example|
    Dir.mktmpdir('impact-artifacts') do |dir|
      @root = Pathname.new(dir)
      example.run
    end
  end

  let(:reader) { instance_double(Woods::PublishedIndex, payload_dir: @root) }
  let(:artifacts) { described_class.new(reader) }

  it 'rejects traversal and symlink components before reading JSON' do
    FileUtils.mkdir_p(@root.join('actual'))
    @root.join('actual', 'index.json').write('{}')
    File.symlink(@root.join('actual'), @root.join('flows'))
    expect { artifacts.read('flows/index.json') }.to raise_error(IOError, /Symlink/)
    expect { artifacts.read('flows/../actual/index.json') }.to raise_error(IOError)
    expect { artifacts.read('/outside.json') }.to raise_error(IOError)
  end

  it 'rejects corrupt, invalidly encoded and oversized artifacts' do
    @root.join('graph.json').binwrite("\xff")
    expect { artifacts.read('graph.json') }.to raise_error(IOError, /UTF-8/)
    @root.join('graph.json').write('{ invalid')
    expect { artifacts.read('graph.json') }.to raise_error(JSON::ParserError)
    File.open(@root.join('graph.json'), 'w') { |file| file.truncate(described_class::MAX_BYTES + 1) }
    expect { artifacts.read('graph.json') }.to raise_error(IOError, /bounded/)
  end
end
