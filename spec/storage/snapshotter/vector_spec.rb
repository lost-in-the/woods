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

  describe '.load_or_empty' do
    it 'returns an InMemory vector store' do
      store = described_class.load_or_empty(artifact)
      expect(store).to be_a(Woods::Storage::VectorStore::InMemory)
    end

    it 'returns an empty store' do
      store = described_class.load_or_empty(artifact)
      expect(store.count).to eq(0)
    end

    it 'ignores artifact state — returns empty even when latest_dump_path is set' do
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

  describe '.dump' do
    let(:dump_dir) { artifact.new_dump_dir }

    context 'with a valid in-memory store (happy path)' do
      let(:store) do
        s = Woods::Storage::VectorStore::InMemory.new
        s.store('unit1', [0.1, 0.2, 0.3], { type: 'model' })
        s
      end

      it 'does not raise for valid input' do
        expect { described_class.dump(store, artifact, dump_dir) }.not_to raise_error
      end

      it 'returns nil (no-op)' do
        expect(described_class.dump(store, artifact, dump_dir)).to be_nil
      end

      it 'writes no files (stub no-op)' do
        described_class.dump(store, artifact, dump_dir)
        written = Dir.glob("#{dump_dir}/**/*").reject { |f| File.directory?(f) }
        expect(written).to be_empty
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
end
