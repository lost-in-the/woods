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

  it 'writes payload files without per-file flushes and flushes the tree once before publishing' do
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
      # Payload files are written into the writer's private stage, which is
      # then promoted to the published payload.
      stage = File.join(Woods::PayloadStore.new(out).root.to_s, Woods::PayloadStore::STAGE_PREFIX)
      payload_writes, other_writes = events.select { |e| e.first == :write }.partition { |e| e[1].start_with?(stage) }
      expect(payload_writes).not_to be_empty
      expect(payload_writes.map(&:last).uniq).to eq([false])
      # The generation pointer and anything outside the payload keep their own flush.
      expect(other_writes.map(&:last).uniq).to eq([true])
      sync_at = events.index { |e| e.first == :sync }
      publish_at = events.index { |e| e.first == :publish }
      expect(sync_at).not_to be_nil
      expect(publish_at).not_to be_nil
      expect(sync_at).to be < publish_at
      expect(events[sync_at].last).to start_with(stage)
    end
  end

  # A child forked inside the publish block inherits the stage and the lock
  # and unwinds publish's stage cleanup and with_lock's release. Both belong
  # to the parent, which must still promote and publish.
  describe 'a child forked while the self-map is staged', if: Process.respond_to?(:fork) do
    { 'returns normally' => :return, 'raises' => :raise, 'calls exit!' => :exit! }.each do |exit_kind, mode|
      it "leaves the parent's stage and lock alone when the child #{exit_kind}, and the parent still publishes" do
        Dir.mktmpdir('woods_self_map_fork') do |out|
          lock_path = File.join(out, "#{Woods::GemMapPublication::LOCK_NAME}.lock")
          seen = publish_with_child(Woods::GemMapPublication.new(out), mode) do |stage|
            { stage_kept: File.file?(File.join(stage, 'parent.json')), lock_kept: File.exist?(lock_path) }
          end

          expect(seen).to eq(stage_kept: true, lock_kept: true)
          expect(Woods::Generation.new(output_dir: out).current.number).to eq(1)
          expect(File.file?(File.join(out, Woods::PayloadStore.name_for(1), 'parent.json'))).to be(true)
          expect(Dir.children(File.join(out, 'payloads')).grep(/\A\.stage-/)).to be_empty
          expect(File.exist?(lock_path)).to be(false)
        end
      end
    end

    # Forks inside the publish block. The child leaves as +mode+ says and is
    # stopped before RSpec's cleanup; the parent yields the stage once the
    # child is gone and returns what the block saw.
    def publish_with_child(publication, mode)
      seen = nil
      in_child = false
      publication.with_lock do
        publication.publish do |stage|
          File.write(File.join(stage, 'parent.json'), '{}')
          child = fork
          in_child = child.nil?
          next leave_publish(mode) if in_child

          Process.wait(child)
          seen = yield stage
        end
      end
      seen
    rescue StandardError
      raise unless in_child
    ensure
      exit!(0) if in_child
    end

    def leave_publish(mode)
      exit!(0) if mode == :exit!
      raise 'the child failed' if mode == :raise
    end
  end

  # Two self-map writers are ordinary (`bin/woods-self-mcp` refreshes in the
  # background). One whose lock is taken over before it publishes must change
  # nothing its successor owns.
  describe 'a self-map writer whose lock is taken over before publishing' do
    after { Woods::PublicationSeam.hook = nil }

    def tiny_gem(dir)
      gem_root = File.join(dir, 'gem')
      FileUtils.mkdir_p(File.join(gem_root, 'lib'))
      File.write(File.join(gem_root, 'lib/tiny.rb'), "module Tiny; end\n")
      gem_root
    end

    it 'publishes nothing, prunes nothing and removes only its own stage' do
      Dir.mktmpdir('woods_self_map_fence') do |dir|
        out = File.join(dir, 'out')
        successor = nil
        theirs = nil
        Woods::PublicationSeam.hook = lambda do |point, _dir|
          next unless point == :before_promotion

          lock_path = File.join(out, "#{described_class::LOCK_NAME}.lock")
          old = Time.now - 7200
          File.utime(old, old, lock_path)
          successor = Woods::Coordination::PipelineLock.new(lock_dir: out, name: described_class::LOCK_NAME)
          raise 'takeover failed' unless successor.acquire

          theirs = Woods::PayloadStore.new(out).create_stage(1, successor.token)
        end

        expect { described_class.new(root: tiny_gem(dir), output_dir: out).map! }
          .to raise_error(Woods::Coordination::LockLostError)

        expect(Woods::Generation.new(output_dir: out).current.number).to eq(0)
        expect(Dir.children(File.join(out, 'payloads')).grep(/\A(gen-|\.stage-)/)).to eq([theirs.basename.to_s])
        expect(theirs).to be_directory
        successor.release
      end
    end

    it 'refuses to republish as generation 1 over a corrupt marker' do
      Dir.mktmpdir('woods_self_map_corrupt') do |dir|
        out = File.join(dir, 'out')
        described_class.new(root: tiny_gem(dir), output_dir: out).map!
        sentinel = File.join(out, Woods::PayloadStore.name_for(1), 'sentinel.json')
        File.write(sentinel, 'kept')
        marker = File.join(out, Woods::Generation::FILENAME)
        File.write(marker, '{broken')

        expect { described_class.new(root: tiny_gem(dir), output_dir: out).map! }
          .to raise_error(Woods::Generation::InvalidMarker)

        expect(File.read(marker)).to eq('{broken')
        expect(File.read(sentinel)).to eq('kept')
        expect(Dir.children(File.join(out, 'payloads')).grep(/\A\.stage-/)).to be_empty
      end
    end

    it 'publishes from a private stage when uncontested' do
      Dir.mktmpdir('woods_self_map_fence') do |dir|
        out = File.join(dir, 'out')

        expect(described_class.new(root: tiny_gem(dir), output_dir: out).map!).to include(status: :published,
                                                                                          generation: 1)
        expect(Dir.children(File.join(out, 'payloads')).grep(/\A\.stage-/)).to be_empty
      end
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
