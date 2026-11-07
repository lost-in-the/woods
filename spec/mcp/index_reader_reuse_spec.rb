# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'json'
require 'woods'
require 'woods/filename_utils'
require 'woods/mcp/index_reader'

# IndexReader#each_unit lets a bulk consumer keep the units it decoded, by
# unit file and file identity, so a generation seeded from the one before
# (every unchanged unit file a hard link of the earlier one) decodes only
# what changed. The reader still stats every file and still refuses symlinks
# and non-regular files before it consults the consumer's table.
RSpec.describe Woods::MCP::IndexReader, 'unit reuse by file identity' do
  let(:index_dir) { Dir.mktmpdir('woods-reader-reuse') }
  let(:fixture_dir) { File.expand_path('../fixtures/woods', __dir__) }
  let(:reuse) do
    Class.new do
      attr_reader :stored, :fetched, :table

      def initialize
        @table = {}
        @stored = []
        @fetched = []
      end

      def fetch(key, identity)
        @fetched << [key, identity]
        entry = @table[key]
        entry.last if entry && entry.first == identity
      end

      def store(key, identity, unit)
        @stored << [key, identity]
        @table[key] = [identity, unit]
      end
    end.new
  end

  after { FileUtils.rm_rf(index_dir) }

  def publish(name, from: nil, except: [])
    relative = "payloads/#{name}"
    target = File.join(index_dir, relative)
    if from
      seed(File.join(index_dir, "payloads/#{from}"), target, except)
    else
      FileUtils.mkdir_p(target)
      FileUtils.cp_r("#{fixture_dir}/.", target)
    end
    yield target if block_given?
    Woods::Generation.new(output_dir: index_dir).bump!(payload: relative)
  end

  # What Woods' payload seeding leaves: every file of +source+ hard-linked
  # into +target+, except the ones named, which are copied.
  def seed(source, target, except)
    Dir.glob('**/*', base: source).sort.each do |entry|
      src = File.join(source, entry)
      dst = File.join(target, entry)
      FileUtils.mkdir_p(File.dirname(dst))
      next FileUtils.mkdir_p(dst) if File.directory?(src)

      except.include?(entry) ? FileUtils.cp(src, dst) : File.link(src, dst)
    end
  end

  def post_file
    "models/#{Object.new.extend(Woods::FilenameUtils).collision_safe_filename('Post')}"
  end

  it 'tells the table every unit it decoded, keyed by unit file with a five-part file identity' do
    publish('gen-1')
    units = described_class.new(index_dir).each_unit(reuse: reuse).to_a

    expect(units.size).to be > 1
    expect(reuse.stored.size).to eq(units.size)
    expect(reuse.stored.map(&:first)).to all(match([String, /\.json\z/]))
    expect(reuse.stored.map(&:last)).to all(match([Integer, Integer, Integer, Integer, Integer]))
    expect(reuse.stored.map(&:last).uniq.size).to eq(units.size)
  end

  it 'yields the table\'s unit for a hard-linked file and decodes only a rewritten one' do
    publish('gen-1')
    reader = described_class.new(index_dir)
    first = reader.each_unit(reuse: reuse).to_a
    publish('gen-2', from: 'gen-1', except: [post_file]) do |target|
      path = File.join(target, post_file)
      data = JSON.parse(File.read(path))
      data['source_code'] = "#{data['source_code']}\n# rewritten"
      File.write(path, JSON.generate(data))
    end
    reuse.stored.clear

    second = reader.each_unit(reuse: reuse).to_a

    reused = second.select { |unit| first.any? { |earlier| earlier.equal?(unit) } }
    expect(reused.size).to eq(first.size - 1)
    expect(reuse.stored.map(&:first)).to eq([post_file.split('/', 2)])
    expect(second.find { |unit| unit['identifier'] == 'Post' }['source_code']).to end_with('# rewritten')
  end

  it 'decodes a file whose identity changed even when its bytes did not' do
    publish('gen-1')
    reader = described_class.new(index_dir)
    reader.each_unit(reuse: reuse).to_a
    publish('gen-2', from: 'gen-1', except: [post_file])
    reuse.stored.clear

    reader.each_unit(reuse: reuse).to_a

    expect(reuse.stored.map(&:first)).to eq([post_file.split('/', 2)])
  end

  it 'refuses a symlinked unit file before consulting the table' do
    publish('gen-1')
    reader = described_class.new(index_dir)
    reader.each_unit(reuse: reuse).to_a
    publish('gen-2', from: 'gen-1', except: [post_file]) do |target|
      path = File.join(target, post_file)
      File.delete(path)
      File.symlink(File.join(index_dir, 'payloads/gen-1', post_file), path)
    end

    expect { reader.each_unit(reuse: reuse).to_a }.to raise_error(IOError, /symlink unit file/)
  end

  it 'reads every file when no table is given' do
    publish('gen-1')
    reader = described_class.new(index_dir)
    first = reader.each_unit.to_a
    second = reader.each_unit.to_a

    expect(second.zip(first).none? { |a, b| a.equal?(b) }).to be(true)
  end
end
