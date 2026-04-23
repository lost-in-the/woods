# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'pathname'
require 'woods/storage/snapshotter/vector'
require 'woods/index_artifact'

RSpec.describe Woods::Storage::Snapshotter::Vector do
  let(:tmpdir) { Dir.mktmpdir }
  let(:artifact) { Woods::IndexArtifact.new(tmpdir) }

  after { FileUtils.remove_entry(tmpdir) }

  # --- helpers ---

  def make_store(entries)
    s = Woods::Storage::VectorStore::InMemory.new
    entries.each { |id, vec, meta| s.store(id, vec, meta || {}) }
    s
  end

  def random_vector(dim)
    Array.new(dim) { rand(-1.0..1.0) }
  end

  def dump_and_load(store, resolved_config: nil)
    dump_dir = artifact.new_dump_dir
    artifact.promote(dump_dir)
    described_class.dump(store, artifact, dump_dir, resolved_config: resolved_config)
    described_class.load_or_empty(artifact, resolved_config: resolved_config)
  end

  # --- stub-retained: load_or_empty ---

  describe '.load_or_empty' do
    it 'returns an InMemory vector store' do
      store = described_class.load_or_empty(artifact)
      expect(store).to be_a(Woods::Storage::VectorStore::InMemory)
    end

    it 'returns an empty store when no dump exists' do
      store = described_class.load_or_empty(artifact)
      expect(store.count).to eq(0)
    end

    it 'returns an empty store when latest_dump_path exists but vectors.bin is absent' do
      dump_dir = artifact.new_dump_dir
      artifact.promote(dump_dir)
      store = described_class.load_or_empty(artifact)
      expect(store.count).to eq(0)
    end

    it 'accepts an optional resolved_config keyword without error' do
      expect { described_class.load_or_empty(artifact, resolved_config: double('rc')) }
        .not_to raise_error
    end
  end

  # --- stub-retained: dump input validation ---

  describe '.dump' do
    let(:dump_dir) { artifact.new_dump_dir }

    context 'with a valid in-memory store (stub-era happy path)' do
      let(:store) do
        s = Woods::Storage::VectorStore::InMemory.new
        s.store('unit1', [0.1, 0.2, 0.3], { type: 'model' })
        s
      end

      it 'does not raise for valid input' do
        expect { described_class.dump(store, artifact, dump_dir) }.not_to raise_error
      end

      it 'returns nil' do
        expect(described_class.dump(store, artifact, dump_dir)).to be_nil
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
      let(:store) { Woods::Storage::VectorStore::InMemory.new }
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

  # --- real serialization ---

  describe 'round-trip serialization' do
    let(:dim) { 8 }

    it 'round-trips 50 random unit vectors with ids intact' do
      entries = Array.new(50) do |i|
        vec = random_vector(dim)
        mag = Math.sqrt(vec.sum { |x| x * x })
        unit = vec.map { |x| x / mag }
        ["unit_#{i}", unit]
      end
      original = make_store(entries)
      loaded = dump_and_load(original)

      expect(loaded.count).to eq(50)
      entries.each do |id, orig_vec|
        found = loaded.search(orig_vec, limit: 1).first
        expect(found.id).to eq(id)
        expect(found.score).to be_within(1e-5).of(1.0)
      end
    end

    it 'each loaded vector is float32-close to the original' do
      vec = [0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8]
      original = make_store([['v1', vec]])
      loaded = dump_and_load(original)

      loaded_vec = loaded.each_entry.to_a.first[1]
      vec.each_with_index do |orig, i|
        expect(loaded_vec[i]).to be_within(1e-6).of(orig.round(6))
      end
    end

    it 'round-trips a store with tombstoned entries (only live entries dumped)' do
      store = make_store([['a', [1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]],
                          ['b', [0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]],
                          ['c', [0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 0.0]]])
      store.delete('b')

      loaded = dump_and_load(store)
      ids = loaded.each_entry.map { |id, _, _| id }
      expect(ids).to contain_exactly('a', 'c')
      expect(loaded.count).to eq(2)
    end
  end

  describe 'empty store' do
    it 'writes a valid header with vector_count=0' do
      empty = Woods::Storage::VectorStore::InMemory.new
      dump_dir = artifact.new_dump_dir
      artifact.promote(dump_dir)
      described_class.dump(empty, artifact, dump_dir)

      bin_path = dump_dir.join('vectors.bin')
      expect(bin_path.exist?).to be true
      magic = File.binread(bin_path.to_s, 4)
      expect(magic).to eq('WVF1')

      vector_count = File.binread(bin_path.to_s, 8, 12).unpack1('Q<')
      expect(vector_count).to eq(0)
    end

    it 'load_or_empty returns an empty store for a zero-vector dump' do
      empty = Woods::Storage::VectorStore::InMemory.new
      loaded = dump_and_load(empty)
      expect(loaded.count).to eq(0)
    end
  end

  describe 'header validation on load' do
    let(:dump_dir) { artifact.new_dump_dir }

    def write_bin(content)
      path = dump_dir.join('vectors.bin')
      File.binwrite(path.to_s, content)
    end

    def write_idx(content = '')
      path = dump_dir.join('vectors.idx')
      File.binwrite(path.to_s, content)
    end

    before { artifact.promote(dump_dir) }

    it 'raises UnsupportedArtifact when magic bytes are wrong' do
      header = "BAD!#{[1, 0, 0].pack('L<L<L<')}#{[0].pack('Q<')}" \
               "#{[5].pack('L<')}1.2.0#{[0].pack('L<')}"
      write_bin(header)
      write_idx

      expect { described_class.load_or_empty(artifact) }
        .to raise_error(Woods::MCP::UnsupportedArtifact, /invalid magic/)
    end

    it 'includes found bytes in the error details' do
      bad_magic = 'XXXX'
      header = "#{bad_magic}#{[1, 0, 0].pack('L<L<L<')}#{[0].pack('Q<')}" \
               "#{[5].pack('L<')}1.2.0#{[0].pack('L<')}"
      write_bin(header)
      write_idx

      begin
        described_class.load_or_empty(artifact)
      rescue Woods::MCP::UnsupportedArtifact => e
        expect(e.details[:found]).to eq('XXXX')
      end
    end

    it 'raises UnsupportedArtifact when schema_version > supported max' do
      future_version = 2
      header = "WVF1#{[future_version, 8, 0].pack('L<L<L<')}#{[0].pack('Q<')}" \
               "#{[5].pack('L<')}1.2.0#{[0].pack('L<')}"
      write_bin(header)
      write_idx

      expect { described_class.load_or_empty(artifact) }
        .to raise_error(Woods::MCP::UnsupportedArtifact, /schema_version 2/)
    end

    it 'raises DimensionMismatch when stored dim ≠ resolved_config.dimension' do
      store = make_store([['v1', Array.new(8, 0.1)]])
      described_class.dump(store, artifact, dump_dir)

      config = double('rc', dimension: 16)
      expect { described_class.load_or_empty(artifact, resolved_config: config) }
        .to raise_error(Woods::MCP::DimensionMismatch)
    end

    it 'does not raise DimensionMismatch when resolved_config.dimension matches' do
      store = make_store([['v1', Array.new(8, 0.1)]])
      described_class.dump(store, artifact, dump_dir)

      config = double('rc', dimension: 8)
      expect { described_class.load_or_empty(artifact, resolved_config: config) }
        .not_to raise_error
    end

    it 'raises UnsupportedArtifact on a truncated/corrupt file' do
      write_bin('WVF') # only 3 bytes
      write_idx

      expect { described_class.load_or_empty(artifact) }
        .to raise_error(Woods::MCP::UnsupportedArtifact, /too short/)
    end
  end

  describe 'atomic file writes' do
    it 'calls File.rename with a tmp path for vectors.bin' do
      store = make_store([['v1', [0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8]]])
      dump_dir = artifact.new_dump_dir

      renamed_paths = []
      original_rename = File.method(:rename)
      allow(File).to receive(:rename) do |src, dst|
        renamed_paths << [src, dst]
        original_rename.call(src, dst)
      end

      described_class.dump(store, artifact, dump_dir)

      bin_renames = renamed_paths.select { |_, dst| dst.end_with?('vectors.bin') }
      expect(bin_renames.size).to eq(1)
      src_path = bin_renames.first[0]
      expect(src_path).to include('.woods-vec-')
    end
  end

  describe 'schema version header field' do
    it 'writes schema_version=1 in every dump' do
      store = make_store([['v1', [1.0, 0.0, 0.0, 0.0]]])
      dump_dir = artifact.new_dump_dir
      described_class.dump(store, artifact, dump_dir)

      bin_path = dump_dir.join('vectors.bin')
      version = File.binread(bin_path.to_s, 4, 4).unpack1('L<')
      expect(version).to eq(1)
    end
  end

  describe 'resolved_config integration' do
    let(:dim) { 4 }
    let(:config) { double('rc', dimension: dim, model_name: 'nomic-embed-text') }

    it 'accepts resolved_config on dump without raising' do
      store = make_store([['id1', Array.new(dim, 0.5)]])
      dump_dir = artifact.new_dump_dir
      artifact.promote(dump_dir)

      expect do
        described_class.dump(store, artifact, dump_dir, resolved_config: config)
      end.not_to raise_error
    end

    it 'round-trips with resolved_config on both sides' do
      store = make_store([['id1', [0.1, 0.2, 0.3, 0.4]],
                          ['id2', [0.9, 0.8, 0.7, 0.6]]])
      dump_dir = artifact.new_dump_dir
      artifact.promote(dump_dir)
      described_class.dump(store, artifact, dump_dir, resolved_config: config)

      loaded = described_class.load_or_empty(artifact, resolved_config: config)
      expect(loaded.count).to eq(2)
    end
  end
end
