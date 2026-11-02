# frozen_string_literal: true

require 'spec_helper'
require 'fileutils'
require 'json'
require 'tmpdir'
require 'open3'
require 'woods/gem_mapper'
require 'woods/mcp/index_reader'

RSpec.describe Woods::GemMapper do
  let(:root) { File.expand_path('..', __dir__) }

  # Mapping the whole checkout takes seconds, so the read-only examples share one map.
  before(:all) do
    @shared_output_dir = Dir.mktmpdir('woods_self_map')
    @shared_result = described_class.new(root: File.expand_path('..', __dir__), output_dir: @shared_output_dir).map!
  end

  after(:all) { FileUtils.rm_rf(@shared_output_dir) }

  def output_dir
    @shared_output_dir
  end

  def payload_dir
    Woods::Generation.new(output_dir: output_dir).payload_dir
  end

  it 'publishes a complete, MCP-readable static source generation' do
    expect(@shared_result).to include(status: :published, generation: 1)
    expect(payload_dir.join('manifest.json')).to be_file
    expect(payload_dir.join('ruby_classes', '_index.json')).to be_file
    expect(payload_dir.join('ruby_modules', '_index.json')).to be_file
    expect(payload_dir.join('ruby_methods', '_index.json')).to be_file
    expect(payload_dir.join('ruby_files', '_index.json')).to be_file

    reader = Woods::MCP::IndexReader.new(output_dir)
    expect(reader.manifest.dig('provenance', 'mode')).to eq('woods_static_ruby_source')
    expect(reader.manifest['woods_version']).to eq(Woods::VERSION)
    expect(reader.find_unit('Woods::Extractor')).to include('file_path' => 'lib/woods/extractor.rb')
    expect(reader.find_unit('Woods::RubyAnalyzer')).not_to be_nil
    expect(reader.find_unit('Woods::MCP::IndexReader')).not_to be_nil
    expect(reader.search('Woods::Extractor', types: ['ruby_class'])[:results].map { |entry| entry[:identifier] })
      .to include('Woods::Extractor')
    expect(reader.traverse_dependencies('Woods::MCP::IndexReader')[:found]).to be(true)
  end

  it 'preserves source-map types for MCP filtering' do
    unit = Woods::MCP::IndexReader.new(output_dir).find_unit('Woods::RubyAnalyzer')
    expect(unit).to include('type' => 'ruby_module')
    expect(reader = Woods::MCP::IndexReader.new(output_dir)).to be_a(Woods::MCP::IndexReader)
    expect(reader.search('Woods::RubyAnalyzer', types: ['ruby_module'])[:results])
      .to include(hash_including(identifier: 'Woods::RubyAnalyzer', type: 'ruby_module'))
  end

  it 'names each unit type in its type index' do
    entries = JSON.parse(payload_dir.join('ruby_modules', '_index.json').read)
    expect(entries).to all(include('type' => 'ruby_module'))
  end

  it 'writes payload files without per-file flushes and flushes the tree once before publishing (WDS-101)' do
    Dir.mktmpdir('woods_self_map_sync') do |dir|
      gem_root = File.join(dir, 'gem')
      FileUtils.mkdir_p(File.join(gem_root, 'lib/tiny'))
      File.write(File.join(gem_root, 'lib/tiny.rb'), "module Tiny; end\n")
      File.write(File.join(gem_root, 'lib/tiny/thing.rb'), "module Tiny\n  class Thing; end\nend\n")
      out = File.join(dir, 'out')

      events = []
      allow(Woods::AtomicFile).to receive(:write).and_wrap_original do |m, *args, **kw|
        events << [:write, args.first.to_s, kw.fetch(:durable, true)]
        m.call(*args, **kw)
      end
      allow(Woods::AtomicFile).to receive(:sync_directory_tree).and_wrap_original do |m, *args|
        events << [:sync, args.first.to_s]
        m.call(*args)
      end
      allow(Woods::Generation).to receive(:new).and_wrap_original do |m, *args, **kw|
        m.call(*args, **kw).tap do |gen|
          allow(gen).to receive(:bump!).and_wrap_original do |bump, *a, **k|
            events << [:publish]
            bump.call(*a, **k)
          end
        end
      end

      result = described_class.new(root: gem_root, output_dir: out).map!

      expect(result).to include(status: :published)
      payload = Woods::Generation.new(output_dir: out).payload_dir.to_s
      payload_writes, other_writes = events.select { |e| e.first == :write }.partition { |e| e[1].start_with?(payload) }
      expect(payload_writes).not_to be_empty
      expect(payload_writes.map(&:last).uniq).to eq([false])
      # The generation pointer and anything outside the payload keep their own flush.
      expect(other_writes.map(&:last).uniq).to eq([true])
      sync_at = events.index { |e| e.first == :sync }
      publish_at = events.index { |e| e.first == :publish }
      expect(sync_at).not_to be_nil
      expect(publish_at).not_to be_nil
      expect(sync_at).to be < publish_at
      expect(events[sync_at].last).to eq(payload)
    end
  end

  it 'skips an unchanged tree without advancing the generation' do
    mapper = described_class.new(root: root, output_dir: output_dir)
    original_manifest = File.binread(payload_dir.join('manifest.json'))

    expect(mapper.map!).to include(status: :skipped, generation: 1)
    expect(File.binread(payload_dir.join('manifest.json'))).to eq(original_manifest)
  end

  it 'writes only repository-relative source paths' do
    entries = Dir[payload_dir.join('ruby_*', '_index.json').to_s].flat_map { |path| JSON.parse(File.read(path)) }
    expect(entries.map { |entry| entry['file_path'] }).to all(satisfy { |path| !path.start_with?('/') })
    expect(entries.map { |entry| entry['file_path'] }).to include('lib/tasks/woods.rake', 'exe/woods-mcp')
  end

  it 'records its writer version when loaded as a standalone mapper (#323)' do
    standalone_dir = Dir.mktmpdir('woods_self_map_standalone')
    script = <<~RUBY
      require 'woods/gem_mapper'
      Woods::GemMapper.new(root: ARGV[0], output_dir: ARGV[1]).map!
      payload = Woods::Generation.new(output_dir: ARGV[1]).payload_dir
      puts JSON.parse(File.read(payload.join('manifest.json'))).fetch('woods_version')
    RUBY
    out, err, status = Open3.capture3(RbConfig.ruby, '-I', File.join(root, 'lib'), '-e', script, root, standalone_dir)
    expect(status).to be_success, err
    expect(out.strip).to eq(Woods::VERSION)
  ensure
    FileUtils.rm_rf(standalone_dir)
  end
end
