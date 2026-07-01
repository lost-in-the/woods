# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'json'
require 'woods'
require 'woods/index_artifact'

RSpec.describe Woods::IndexArtifact do
  subject(:artifact) { described_class.new(tmpdir) }

  let(:tmpdir) { Dir.mktmpdir }

  after { FileUtils.rm_rf(tmpdir) }

  describe '#output_dir' do
    it 'returns a Pathname equal to the constructor argument' do
      expect(artifact.output_dir).to eq(Pathname.new(tmpdir))
    end
  end

  describe '#config_path' do
    it 'returns a Pathname under output_dir named woods.json' do
      expect(artifact.config_path).to eq(Pathname.new(tmpdir).join('woods.json'))
    end
  end

  describe '#dumps_root' do
    it 'returns a Pathname named dumps under output_dir' do
      expect(artifact.dumps_root).to eq(Pathname.new(tmpdir).join('dumps'))
    end
  end

  describe '#latest_pointer_path' do
    it 'returns a Pathname for dumps/latest (may not exist)' do
      expect(artifact.latest_pointer_path).to eq(Pathname.new(tmpdir).join('dumps', 'latest'))
    end
  end

  describe '#fresh?' do
    context 'when neither woods.json nor dumps/latest exists' do
      it 'returns true' do
        expect(artifact.fresh?).to be(true)
      end
    end

    context 'when woods.json exists but dumps/latest does not' do
      before { artifact.write_config('schema_version' => 1) }

      it 'returns false — artifact is non-fresh once config is written' do
        expect(artifact.fresh?).to be(false)
      end
    end

    context 'when dumps/latest exists but woods.json does not' do
      before do
        FileUtils.mkdir_p(artifact.dumps_root)
        File.write(artifact.latest_pointer_path, '2026-04-23T03-42-17Z')
      end

      it 'returns false — presence of the pointer alone marks the artifact non-fresh' do
        expect(artifact.fresh?).to be(false)
      end
    end

    context 'when both woods.json and dumps/latest exist' do
      before do
        artifact.write_config('schema_version' => 1)
        FileUtils.mkdir_p(artifact.dumps_root)
        File.write(artifact.latest_pointer_path, '2026-04-23T03-42-17Z')
      end

      it 'returns false' do
        expect(artifact.fresh?).to be(false)
      end
    end
  end

  describe '#latest_dump_path' do
    context 'when no latest pointer exists' do
      it 'returns nil' do
        expect(artifact.latest_dump_path).to be_nil
      end
    end

    context 'when latest pointer is empty' do
      before do
        FileUtils.mkdir_p(artifact.dumps_root)
        File.write(artifact.latest_pointer_path, '')
      end

      it 'returns nil' do
        expect(artifact.latest_dump_path).to be_nil
      end
    end

    context 'when latest pointer names a directory that exists' do
      let(:dump_name) { '2026-04-23T03-42-17Z' }

      before do
        FileUtils.mkdir_p(artifact.dumps_root.join(dump_name))
        File.write(artifact.latest_pointer_path, dump_name)
      end

      it 'returns a Pathname to that directory' do
        expect(artifact.latest_dump_path).to eq(artifact.dumps_root.join(dump_name))
      end
    end

    context 'when latest pointer names a directory that no longer exists (stale)' do
      before do
        FileUtils.mkdir_p(artifact.dumps_root)
        File.write(artifact.latest_pointer_path, '2026-04-23T01-00-00Z')
      end

      it 'returns nil' do
        expect(artifact.latest_dump_path).to be_nil
      end
    end

    context 'when latest pointer has trailing whitespace' do
      let(:dump_name) { '2026-04-23T03-42-17Z' }

      before do
        FileUtils.mkdir_p(artifact.dumps_root.join(dump_name))
        File.write(artifact.latest_pointer_path, "#{dump_name}\n")
      end

      it 'strips the newline and returns the correct path' do
        expect(artifact.latest_dump_path.basename.to_s).to eq(dump_name)
      end
    end
  end

  describe '#new_dump_dir' do
    it 'creates a directory under dumps_root with a filesystem-safe UTC timestamp name' do
      now = Time.utc(2026, 4, 23, 3, 42, 17)
      dir = artifact.new_dump_dir(now: now)
      expect(dir.to_s).to end_with('dumps/2026-04-23T03-42-17Z')
      expect(dir).to be_directory
    end

    it 'uses dashes not colons in the time portion' do
      dir = artifact.new_dump_dir(now: Time.utc(2026, 4, 23, 3, 42, 17))
      expect(dir.basename.to_s).not_to include(':')
    end

    it 'creates dumps_root if it does not exist' do
      expect(artifact.dumps_root).not_to be_directory
      artifact.new_dump_dir
      expect(artifact.dumps_root).to be_directory
    end

    it 'uses UTC now by default (smoke test: does not raise)' do
      expect { artifact.new_dump_dir }.not_to raise_error
    end

    it 'raises when the target directory already exists' do
      now = Time.utc(2026, 4, 23, 3, 42, 17)
      artifact.new_dump_dir(now: now)
      expect { artifact.new_dump_dir(now: now) }.to raise_error(Errno::EEXIST)
    end
  end

  describe '#promote' do
    let(:dump_dir) { artifact.new_dump_dir(now: Time.utc(2026, 4, 23, 3, 42, 17)) }

    it 'writes the directory basename to the latest pointer' do
      artifact.promote(dump_dir)
      expect(artifact.latest_pointer_path.read.strip).to eq('2026-04-23T03-42-17Z')
    end

    it 'makes latest_dump_path return the promoted directory' do
      artifact.promote(dump_dir)
      expect(artifact.latest_dump_path).to eq(dump_dir)
    end

    it 'accepts a String path as well as a Pathname' do
      artifact.promote(dump_dir.to_s)
      expect(artifact.latest_dump_path).to eq(dump_dir)
    end

    it 'overwrites an existing pointer atomically' do
      old_dir = artifact.new_dump_dir(now: Time.utc(2026, 4, 23, 2, 0, 0))
      artifact.promote(old_dir)
      new_dir = artifact.new_dump_dir(now: Time.utc(2026, 4, 23, 3, 42, 17))
      artifact.promote(new_dir)
      expect(artifact.latest_dump_path).to eq(new_dir)
    end

    it 'uses a tmp file + rename (atomic write pattern)' do
      rename_calls = []
      allow(File).to receive(:rename).and_wrap_original do |orig, src, dst|
        rename_calls << [src, dst]
        orig.call(src, dst)
      end
      artifact.promote(dump_dir)
      expect(rename_calls).not_to be_empty
      expect(rename_calls.last[1]).to eq(artifact.latest_pointer_path.to_s)
    end

    it 'raises ArgumentError for a directory outside dumps_root' do
      outside = Pathname.new(Dir.mktmpdir)
      expect { artifact.promote(outside) }.to raise_error(ArgumentError, /dumps_root/)
    ensure
      FileUtils.rm_rf(outside.to_s) if outside
    end

    it 'raises ArgumentError for a sibling directory whose name merely prefixes with dumps_root' do
      # ".../dumps-evil" passes a bare start_with?(".../dumps") check; the
      # containment test must require a path-separator boundary.
      sibling = Pathname.new("#{artifact.dumps_root}-evil")
      FileUtils.mkdir_p(sibling.to_s)
      expect { artifact.promote(sibling) }.to raise_error(ArgumentError, /dumps_root/)
    ensure
      FileUtils.rm_rf(sibling.to_s) if sibling
    end

    it 'raises ArgumentError when dump_dir does not exist' do
      ghost = artifact.dumps_root.join('2099-01-01T00-00-00Z')
      expect { artifact.promote(ghost) }.to raise_error(ArgumentError)
    end
  end

  describe '#read_config' do
    context 'when woods.json does not exist' do
      it 'returns nil' do
        expect(artifact.read_config).to be_nil
      end
    end

    context 'when woods.json contains valid JSON' do
      before do
        artifact.write_config('schema_version' => 1, 'gem_version' => '1.2.0')
      end

      it 'returns the parsed hash' do
        result = artifact.read_config
        expect(result).to be_a(Hash)
        expect(result['schema_version']).to eq(1)
      end

      it 'does not raise for a future schema_version (validation is the caller\'s job)' do
        artifact.write_config('schema_version' => 999)
        expect { artifact.read_config }.not_to raise_error
      end
    end

    it 'round-trips with write_config' do
      payload = { 'schema_version' => 1, 'model' => 'nomic-embed-text' }
      artifact.write_config(payload)
      expect(artifact.read_config).to include(payload)
    end
  end

  describe '#write_config' do
    context 'with a plain Hash' do
      it 'writes JSON to woods.json' do
        artifact.write_config('schema_version' => 1, 'gem_version' => '1.2.0')
        data = JSON.parse(artifact.config_path.read)
        expect(data['schema_version']).to eq(1)
      end
    end

    context 'with a ResolvedConfig-like object responding to #to_snapshot_json' do
      let(:fake_config) do
        Object.new.tap do |o|
          o.define_singleton_method(:to_snapshot_json) { '{"schema_version":1}' }
        end
      end

      it 'delegates serialization to the object' do
        artifact.write_config(fake_config)
        expect(artifact.config_path.read).to eq('{"schema_version":1}')
      end
    end

    it 'is atomic — uses tmp file + rename' do
      rename_calls = []
      allow(File).to receive(:rename).and_wrap_original do |orig, src, dst|
        rename_calls << [src, dst]
        orig.call(src, dst)
      end
      artifact.write_config('schema_version' => 1)
      expect(rename_calls.last[1]).to eq(artifact.config_path.to_s)
    end

    it 'creates output_dir parent directories if needed' do
      nested = described_class.new(File.join(tmpdir, 'a', 'b', 'c'))
      nested.write_config('schema_version' => 1)
      expect(File.exist?(nested.config_path)).to be(true)
    end
  end
end
