# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'pathname'
require 'woods/atomic_file'
require 'woods/storage/snapshotter/metadata'
require 'woods/index_artifact'

RSpec.describe Woods::Storage::Snapshotter::Metadata do
  let(:tmpdir) { Dir.mktmpdir }
  let(:artifact) { Woods::IndexArtifact.new(tmpdir) }

  after { FileUtils.remove_entry(tmpdir) }

  def populated_store
    store = Woods::Storage::MetadataStore::InMemory.new
    store.store('User', { 'type' => 'model', 'file_path' => 'app/models/user.rb' })
    store.store('PostsController',
                { 'type' => 'controller', 'file_path' => 'app/controllers/posts_controller.rb' })
    store
  end

  # Read just the header from a metadata.msgpack file.
  def read_header(dump_dir)
    File.open(dump_dir.join('metadata.msgpack').to_s, 'rb') do |io|
      MessagePack::Unpacker.new(io).read
    end
  end

  # Write a raw dump with the given header and optional record array.
  def write_raw_dump(dump_dir, header, records = [])
    dump_dir.mkpath
    File.open(dump_dir.join('metadata.msgpack').to_s, 'wb') do |io|
      packer = MessagePack::Packer.new(io)
      packer.write(header)
      records.each { |r| packer.write(r) }
      packer.flush
    end
  end

  describe 'durability: dump directory fsync (M11)' do
    # AtomicFile fsyncs the containing directory after the rename; the
    # snapshotter's own atomic write skipped that step, so a crash could
    # leave a renamed-but-unflushed directory entry behind.
    it 'fsyncs the dump directory after the atomic rename' do
      dump_dir = artifact.new_dump_dir

      expect(Woods::AtomicFile).to receive(:fsync_directory).with(dump_dir.to_s).and_call_original

      described_class.dump(populated_store, artifact, dump_dir)
    end
  end

  describe '.load_or_empty' do
    it 'returns an InMemory metadata store' do
      expect(described_class.load_or_empty(artifact)).to be_a(Woods::Storage::MetadataStore::InMemory)
    end

    it 'returns an empty store when no dump exists' do
      expect(described_class.load_or_empty(artifact).count).to eq(0)
    end

    it 'returns an empty store when no latest pointer exists (dumps dir present)' do
      artifact.dumps_root.mkpath
      expect(described_class.load_or_empty(artifact).count).to eq(0)
    end

    it 'accepts an optional resolved_config keyword without error' do
      expect { described_class.load_or_empty(artifact, resolved_config: double('rc')) }
        .not_to raise_error
    end

    context 'when a dump has been written' do
      let(:dump_dir) { artifact.new_dump_dir }

      before do
        described_class.dump(populated_store, artifact, dump_dir)
        artifact.promote(dump_dir)
      end

      it 'returns a populated store' do
        expect(described_class.load_or_empty(artifact).count).to eq(2)
      end

      it 'round-trips all record ids' do
        store = described_class.load_or_empty(artifact)
        expect(store.find('User')).not_to be_nil
        expect(store.find('PostsController')).not_to be_nil
      end

      it 'round-trips record field values' do
        meta = described_class.load_or_empty(artifact).find('User')
        expect(meta['type']).to eq('model')
        expect(meta['file_path']).to eq('app/models/user.rb')
      end
    end

    context 'when dump has corrupted magic' do
      let(:dump_dir) { artifact.new_dump_dir }

      before do
        write_raw_dump(dump_dir,
                       { 'magic' => 'XXXX', 'schema_version' => 1, 'record_count' => 0,
                         'gem_version' => '1.2.0', 'created_at' => '2026-01-01T00:00:00Z' })
        artifact.promote(dump_dir)
      end

      it 'raises UnsupportedArtifact' do
        expect { described_class.load_or_empty(artifact) }
          .to raise_error(Woods::MCP::UnsupportedArtifact)
      end

      it 'mentions invalid magic in the error message' do
        expect { described_class.load_or_empty(artifact) }
          .to raise_error(Woods::MCP::UnsupportedArtifact, /invalid magic/)
      end
    end

    context 'when dump has unsupported schema_version' do
      let(:dump_dir) { artifact.new_dump_dir }

      before do
        write_raw_dump(dump_dir,
                       { 'magic' => 'WMD1', 'schema_version' => 999, 'record_count' => 0,
                         'gem_version' => '9.9.9', 'created_at' => '2026-01-01T00:00:00Z' })
        artifact.promote(dump_dir)
      end

      it 'raises UnsupportedArtifact' do
        expect { described_class.load_or_empty(artifact) }
          .to raise_error(Woods::MCP::UnsupportedArtifact)
      end

      it 'includes schema version in the error message' do
        expect { described_class.load_or_empty(artifact) }
          .to raise_error(Woods::MCP::UnsupportedArtifact, /schema_version 999/)
      end
    end
  end

  describe '.dump' do
    let(:dump_dir) { artifact.new_dump_dir }

    context 'with a populated InMemory store (happy path)' do
      let(:store) { populated_store }

      it 'does not raise for valid input' do
        expect { described_class.dump(store, artifact, dump_dir) }.not_to raise_error
      end

      it 'returns nil' do
        expect(described_class.dump(store, artifact, dump_dir)).to be_nil
      end

      it 'writes metadata.msgpack to dump_dir' do
        described_class.dump(store, artifact, dump_dir)
        expect(dump_dir.join('metadata.msgpack')).to exist
      end

      it 'writes a parseable MessagePack stream' do
        described_class.dump(store, artifact, dump_dir)
        expect { read_header(dump_dir) }.not_to raise_error
      end

      it 'writes magic WMD1 in the header' do
        described_class.dump(store, artifact, dump_dir)
        expect(read_header(dump_dir)['magic']).to eq('WMD1')
      end

      it 'writes schema_version 1 in the header' do
        described_class.dump(store, artifact, dump_dir)
        expect(read_header(dump_dir)['schema_version']).to eq(1)
      end

      it 'writes gem_version in the header' do
        described_class.dump(store, artifact, dump_dir)
        expect(read_header(dump_dir)['gem_version']).to eq(Woods::VERSION)
      end

      it 'writes accurate record_count in the header' do
        described_class.dump(store, artifact, dump_dir)
        expect(read_header(dump_dir)['record_count']).to eq(2)
      end

      it 'writes created_at as an ISO8601 timestamp' do
        described_class.dump(store, artifact, dump_dir)
        expect { Time.iso8601(read_header(dump_dir)['created_at']) }.not_to raise_error
      end
    end

    context 'with an empty store' do
      let(:store) { Woods::Storage::MetadataStore::InMemory.new }

      it 'writes a valid file with record_count 0' do
        described_class.dump(store, artifact, dump_dir)
        expect(read_header(dump_dir)['record_count']).to eq(0)
      end
    end

    context 'when store does not respond to #each_entry (persistent backend)' do
      let(:durable_store) { Object.new }

      it 'raises InapplicableBackend' do
        expect { described_class.dump(durable_store, artifact, dump_dir) }
          .to raise_error(Woods::Storage::InapplicableBackend)
      end

      it 'uses the prescribed error message format' do
        expect { described_class.dump(durable_store, artifact, dump_dir) }
          .to raise_error(Woods::Storage::InapplicableBackend,
                          /backend .+ is already durable — Snapshotter should not have been invoked/)
      end
    end

    context 'when store responds to #each_entry but not #bulk_load' do
      let(:partial_store) do
        obj = Object.new
        def obj.each_entry; end
        obj
      end

      it 'raises InapplicableBackend' do
        expect { described_class.dump(partial_store, artifact, dump_dir) }
          .to raise_error(Woods::Storage::InapplicableBackend)
      end
    end

    context 'when dump_dir is outside artifact.dumps_root' do
      let(:store) { Woods::Storage::MetadataStore::InMemory.new }
      let(:outside_dir) { Dir.mktmpdir }

      after { FileUtils.remove_entry(outside_dir) }

      it 'raises ArgumentError' do
        expect { described_class.dump(store, artifact, outside_dir) }
          .to raise_error(ArgumentError)
      end

      it 'mentions dumps_root in the error message' do
        expect { described_class.dump(store, artifact, outside_dir) }
          .to raise_error(ArgumentError, /dumps_root/)
      end
    end
  end

  describe 'round-trip (dump then load)' do
    it 'restores exact record count' do
      store = populated_store
      dump_dir = artifact.new_dump_dir
      described_class.dump(store, artifact, dump_dir)
      artifact.promote(dump_dir)

      expect(described_class.load_or_empty(artifact).count).to eq(2)
    end

    it 'restores metadata field values for all records' do
      dump_dir = artifact.new_dump_dir
      described_class.dump(populated_store, artifact, dump_dir)
      artifact.promote(dump_dir)

      loaded = described_class.load_or_empty(artifact)
      expect(loaded.find('User')['type']).to eq('model')
      expect(loaded.find('PostsController')['type']).to eq('controller')
    end

    it 'handles heterogeneous metadata values (integers, arrays, nested hashes, nil)' do
      store = Woods::Storage::MetadataStore::InMemory.new
      store.store('Complex', {
                    'type' => 'service',
                    'count' => 42,
                    'tags' => %w[auth api],
                    'nested' => { 'depth' => 1 },
                    'nullable' => nil
                  })
      dump_dir = artifact.new_dump_dir
      described_class.dump(store, artifact, dump_dir)
      artifact.promote(dump_dir)

      meta = described_class.load_or_empty(artifact).find('Complex')
      expect(meta['count']).to eq(42)
      expect(meta['tags']).to eq(%w[auth api])
      expect(meta['nested']).to eq({ 'depth' => 1 })
      expect(meta['nullable']).to be_nil
    end

    it 'round-trips 10 records with varied metadata' do
      store = Woods::Storage::MetadataStore::InMemory.new
      10.times do |i|
        store.store("Unit#{i}", {
                      'type' => %w[model controller service][i % 3],
                      'index' => i,
                      'tags' => ["tag#{i}"],
                      'nested' => { 'x' => i * 2 }
                    })
      end

      dump_dir = artifact.new_dump_dir
      described_class.dump(store, artifact, dump_dir)
      artifact.promote(dump_dir)

      loaded = described_class.load_or_empty(artifact)
      expect(loaded.count).to eq(10)
      10.times do |i|
        meta = loaded.find("Unit#{i}")
        expect(meta['index']).to eq(i)
        expect(meta['nested']['x']).to eq(i * 2)
      end
    end
  end
end
