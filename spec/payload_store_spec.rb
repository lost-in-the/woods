# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'woods'
require 'woods/payload_store'

RSpec.describe Woods::PayloadStore do
  subject(:store) { described_class.new(tmpdir) }

  let(:tmpdir) { Dir.mktmpdir }

  after { FileUtils.rm_rf(tmpdir) }

  describe '#root' do
    it 'returns a Pathname named payloads under the output directory' do
      expect(store.root).to eq(Pathname.new(tmpdir).join('payloads'))
    end
  end

  describe '.name_for' do
    it 'is relative to the output directory, which is the pointer contract' do
      expect(described_class.name_for(42)).to eq('payloads/gen-42')
    end
  end

  describe '#create' do
    it 'creates the directory for a generation number' do
      dir = store.create(7)

      expect(dir).to eq(Pathname.new(tmpdir).join('payloads/gen-7'))
      expect(dir).to be_directory
    end

    # A run that raised after building its payload but before bumping leaves a
    # directory nothing points at. Re-using it would publish that run's
    # half-written files alongside this one's.
    it 'empties an orphaned directory left by a failed run' do
      dir = store.create(7)
      File.write(dir.join('stale.json'), '{}')

      reused = store.create(7)

      expect(reused.children).to be_empty
    end
  end

  describe '#clone' do
    it 'reproduces the source tree' do
      source = store.create(1)
      FileUtils.mkdir_p(source.join('models'))
      File.write(source.join('manifest.json'), '{"total_units":1}')
      File.write(source.join('models/Post.json'), '{"identifier":"Post"}')

      target = store.create(2)
      store.clone(source, target)

      expect(target.join('manifest.json').read).to eq('{"total_units":1}')
      expect(target.join('models/Post.json').read).to eq('{"identifier":"Post"}')
    end

    it 'hardlinks rather than copying, so cloning costs no data' do
      source = store.create(1)
      File.write(source.join('manifest.json'), '{}')
      target = store.create(2)

      store.clone(source, target)

      expect(target.join('manifest.json').stat.ino).to eq(source.join('manifest.json').stat.ino)
    end

    # The whole reason hardlinking is safe: every writer against a payload goes
    # through AtomicFile, which renames a fresh tempfile over the path. A
    # rename replaces the directory entry and leaves the old inode alone, so
    # the previous generation keeps its bytes. A bare File.write would edit the
    # inode both generations share and corrupt the one a reader is pinned to.
    it 'leaves the source untouched when an AtomicFile write replaces a clone' do
      source = store.create(1)
      File.write(source.join('manifest.json'), 'v1')
      target = store.create(2)
      store.clone(source, target)

      Woods::AtomicFile.write(target.join('manifest.json'), 'v2')

      expect(source.join('manifest.json').read).to eq('v1')
      expect(target.join('manifest.json').read).to eq('v2')
    end

    it 'is a no-op when the source does not exist' do
      target = store.create(2)

      expect { store.clone(Pathname.new(tmpdir).join('nope'), target) }.not_to raise_error
      expect(target.children).to be_empty
    end
  end

  describe '#prune' do
    it 'keeps the newest generations and removes the rest' do
      (1..5).each { |n| store.create(n) }

      store.prune(keep: 2, protect: 5)

      expect(store.root.children.map { |c| c.basename.to_s }.sort).to eq(%w[gen-4 gen-5])
    end

    # Retention must never take the directory generation.json names, however
    # the counting works out — that is the live index.
    it 'never removes the protected generation' do
      (1..3).each { |n| store.create(n) }

      store.prune(keep: 1, protect: 1)

      expect(store.root.children.map { |c| c.basename.to_s }).to include('gen-1')
    end

    it 'reports which generations it removed' do
      (1..4).each { |n| store.create(n) }

      expect(store.prune(keep: 2, protect: 4)).to contain_exactly(1, 2)
    end

    it 'ignores directories that are not generation payloads' do
      store.create(1)
      FileUtils.mkdir_p(store.root.join('scratch'))

      store.prune(keep: 1, protect: 1)

      expect(store.root.join('scratch')).to be_directory
    end

    it 'is a no-op when no payloads have been published' do
      expect { store.prune(keep: 2, protect: 1) }.not_to raise_error
    end
  end
end
