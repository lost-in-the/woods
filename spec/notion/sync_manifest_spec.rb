# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'json'
require 'woods'
require 'woods/notion/sync_manifest'

RSpec.describe Woods::Notion::SyncManifest do
  around do |example|
    Dir.mktmpdir do |dir|
      @dir = dir
      example.run
    end
  end

  let(:path) { File.join(@dir, 'notion_sync_manifest.json') }
  let(:database_ids) { { data_models: 'db-models', columns: 'db-cols' } }

  subject(:manifest) { described_class.new(path: path, database_ids: database_ids) }

  describe '.content_hash' do
    it 'is stable across hash key insertion order, at every nesting level' do
      a = { 'Nullable' => { checkbox: false }, 'Data Type' => { name: 'uuid', color: 'blue' } }
      b = { 'Data Type' => { color: 'blue', name: 'uuid' }, 'Nullable' => { checkbox: false } }
      expect(described_class.content_hash(a)).to eq(described_class.content_hash(b))
    end

    it 'hashes symbol-keyed and string-keyed payloads identically' do
      a = { 'Data Type' => { select: { name: 'uuid' } } }
      b = { 'Data Type' => { 'select' => { 'name' => 'uuid' } } }
      expect(described_class.content_hash(a)).to eq(described_class.content_hash(b))
    end

    it 'changes when a nested value changes' do
      a = { 'Data Type' => { select: { name: 'bigint' } } }
      b = { 'Data Type' => { select: { name: 'uuid' } } }
      expect(described_class.content_hash(a)).not_to eq(described_class.content_hash(b))
    end

    it 'preserves array order (meaningful in Notion rich text runs)' do
      a = { 'Title' => { title: [{ text: { content: 'x' } }, { text: { content: 'y' } }] } }
      b = { 'Title' => { title: [{ text: { content: 'y' } }, { text: { content: 'x' } }] } }
      expect(described_class.content_hash(a)).not_to eq(described_class.content_hash(b))
    end
  end

  describe 'a fresh manifest' do
    it 'is empty when no file exists' do
      expect(manifest).to be_empty
    end

    it 'treats every page as changed' do
      expect(manifest.unchanged?('data_models', 'users', 'hash-1')).to be(false)
    end

    it 'has no page_id for an unknown key' do
      expect(manifest.page_id_for('data_models', 'users')).to be_nil
    end
  end

  describe '#record and #unchanged?' do
    it 'reports a recorded key+hash as unchanged' do
      manifest.record(scope: 'data_models', key: 'users', hash: 'hash-1', page_id: 'page-1')
      expect(manifest.unchanged?('data_models', 'users', 'hash-1')).to be(true)
    end

    it 'reports a recorded key with a different hash as changed' do
      manifest.record(scope: 'data_models', key: 'users', hash: 'hash-1', page_id: 'page-1')
      expect(manifest.unchanged?('data_models', 'users', 'hash-2')).to be(false)
    end

    it 'never reports unchanged without a recorded page_id' do
      # A skip without a page_id would leave dependents (column Table
      # relations) unable to reference the page — force a re-upsert instead.
      manifest.record(scope: 'data_models', key: 'users', hash: 'hash-1', page_id: nil)
      expect(manifest.unchanged?('data_models', 'users', 'hash-1')).to be(false)
    end

    it 'scopes keys per database — a column key does not satisfy a model lookup' do
      manifest.record(scope: 'columns', key: 'users', hash: 'hash-1', page_id: 'page-1')
      expect(manifest.unchanged?('data_models', 'users', 'hash-1')).to be(false)
    end

    it 'exposes the stored page_id' do
      manifest.record(scope: 'columns', key: 'users.id', hash: 'hash-1', page_id: 'page-9')
      expect(manifest.page_id_for('columns', 'users.id')).to eq('page-9')
    end

    it 'is no longer empty after a record' do
      manifest.record(scope: 'data_models', key: 'users', hash: 'h', page_id: 'p')
      expect(manifest).not_to be_empty
    end

    it 'counts pages across scopes' do
      manifest.record(scope: 'data_models', key: 'users', hash: 'h', page_id: 'p1')
      manifest.record(scope: 'columns', key: 'users.id', hash: 'h', page_id: 'p2')
      expect(manifest.size).to eq(2)
    end
  end

  describe '#forget' do
    it 'removes a key so it is no longer known' do
      manifest.record(scope: 'data_models', key: 'users', hash: 'h', page_id: 'p')
      manifest.forget('data_models', 'users')
      expect(manifest.page_id_for('data_models', 'users')).to be_nil
      expect(manifest.unchanged?('data_models', 'users', 'h')).to be(false)
    end

    it 'tolerates an unknown scope' do
      expect { manifest.forget('data_models', 'users') }.not_to raise_error
    end
  end

  describe '#prune' do
    before do
      manifest.record(scope: 'data_models', key: 'users', hash: 'h', page_id: 'p1')
      manifest.record(scope: 'data_models', key: 'posts', hash: 'h', page_id: 'p2')
      manifest.record(scope: 'columns', key: 'posts.id', hash: 'h', page_id: 'p3')
    end

    it 'drops keys absent from the current set and returns them' do
      expect(manifest.prune('data_models', ['users'])).to contain_exactly('posts')
      expect(manifest.page_id_for('data_models', 'posts')).to be_nil
    end

    it 'leaves other scopes alone' do
      manifest.prune('data_models', [])
      expect(manifest.page_id_for('columns', 'posts.id')).to eq('p3')
    end

    it 'prunes nothing when every key is still present' do
      expect(manifest.prune('data_models', %w[users posts])).to eq([])
    end

    it 'returns an empty list for an unknown scope' do
      expect(manifest.prune('unknown', [])).to eq([])
    end
  end

  describe '#save and reload' do
    it 'round-trips records through the JSON file' do
      manifest.record(scope: 'data_models', key: 'users', hash: 'hash-1', page_id: 'page-1')
      manifest.save

      reloaded = described_class.new(path: path, database_ids: database_ids)
      expect(reloaded.unchanged?('data_models', 'users', 'hash-1')).to be(true)
      expect(reloaded.page_id_for('data_models', 'users')).to eq('page-1')
    end

    it 'creates the parent directory if missing' do
      nested = File.join(@dir, 'sub', 'dir', 'manifest.json')
      m = described_class.new(path: nested, database_ids: database_ids)
      m.record(scope: 'data_models', key: 'users', hash: 'h', page_id: 'p')
      expect { m.save }.not_to raise_error
      expect(File.exist?(nested)).to be(true)
    end
  end

  describe 'database guard' do
    it 'discards a scope recorded against a different database id, keeping the rest' do
      described_class.new(path: path, database_ids: { data_models: 'db-OLD', columns: 'db-cols' }).tap do |old|
        old.record(scope: 'data_models', key: 'users', hash: 'h', page_id: 'p1')
        old.record(scope: 'columns', key: 'users.id', hash: 'h', page_id: 'p2')
        old.save
      end

      reloaded = nil
      expect { reloaded = described_class.new(path: path, database_ids: database_ids) }
        .to output(/scope "data_models".*db-OLD/im).to_stderr
      expect(reloaded.unchanged?('data_models', 'users', 'h')).to be(false)
      expect(reloaded.unchanged?('columns', 'users.id', 'h')).to be(true)
    end

    it 'discards a scope whose database is no longer configured' do
      described_class.new(path: path, database_ids: database_ids).tap do |old|
        old.record(scope: 'columns', key: 'users.id', hash: 'h', page_id: 'p')
        old.save
      end

      reloaded = nil
      expect { reloaded = described_class.new(path: path, database_ids: { data_models: 'db-models' }) }
        .to output(/scope "columns"/i).to_stderr
      expect(reloaded).to be_empty
    end

    it 'loads normally when the persisted database ids match' do
      described_class.new(path: path, database_ids: database_ids).tap do |m|
        m.record(scope: 'columns', key: 'users.id', hash: 'h', page_id: 'p')
        m.save
      end

      reloaded = described_class.new(path: path, database_ids: database_ids)
      expect(reloaded.unchanged?('columns', 'users.id', 'h')).to be(true)
    end

    it 'treats symbol-keyed and string-keyed database_ids configs alike' do
      described_class.new(path: path, database_ids: { 'data_models' => 'db-models' }).tap do |m|
        m.record(scope: 'data_models', key: 'users', hash: 'h', page_id: 'p')
        m.save
      end

      reloaded = described_class.new(path: path, database_ids: { data_models: 'db-models' })
      expect(reloaded.unchanged?('data_models', 'users', 'h')).to be(true)
    end
  end

  describe 'corrupt manifest file' do
    it 'starts empty rather than raising' do
      File.write(path, 'not valid json {{{')
      expect(manifest).to be_empty
    end

    it 'warns to stderr so the resulting full re-check is explainable' do
      File.write(path, 'not valid json {{{')
      expect { described_class.new(path: path, database_ids: database_ids) }
        .to output(/unparseable/i).to_stderr
    end

    it 'discards a manifest whose pages section is malformed' do
      File.write(path, JSON.generate('version' => described_class::VERSION,
                                     'databases' => { 'data_models' => 'db-models' },
                                     'pages' => 'oops'))
      expect { expect(manifest).to be_empty }.to output(/malformed pages/i).to_stderr
    end

    it 'drops individual malformed entries while keeping intact ones' do
      File.write(path, JSON.generate(
                         'version' => described_class::VERSION,
                         'databases' => { 'data_models' => 'db-models' },
                         'pages' => { 'data_models' => {
                           'users' => { 'hash' => 'h', 'page_id' => 'p' },
                           'posts' => 'torn'
                         } }
                       ))
      expect(manifest.unchanged?('data_models', 'users', 'h')).to be(true)
      expect(manifest.unchanged?('data_models', 'posts', 'torn')).to be(false)
    end
  end

  describe 'manifest file containing non-ASCII bytes' do
    # The B-077 / #189 lesson, applied from day one: a bare File.read tags
    # the bytes with the process's default external encoding — US-ASCII
    # under LANG=C, which is how this suite runs — so a non-ASCII page key
    # would raise Encoding::InvalidByteSequenceError out of JSON.parse
    # instead of loading (or degrading). AtomicFile.read keeps this UTF-8.
    before do
      Woods::AtomicFile.write(path, JSON.generate(
                                      'version' => described_class::VERSION,
                                      'databases' => { 'data_models' => 'db-models' },
                                      'pages' => { 'data_models' => {
                                        'café_orders' => { 'hash' => 'h-1', 'page_id' => 'page-1' }
                                      } }
                                    ))
    end

    it 'loads the recorded pages instead of raising' do
      expect(manifest.unchanged?('data_models', 'café_orders', 'h-1')).to be(true)
      expect(manifest.page_id_for('data_models', 'café_orders')).to eq('page-1')
    end
  end

  describe 'unreadable manifest file' do
    # A read failure (permissions, I/O error) must take the same discard
    # path as a corrupt file — the manifest is a cache, and "everything is
    # new" is always a correct answer.
    before do
      File.write(path, '{}')
      allow(Woods::AtomicFile).to receive(:read).and_raise(Errno::EACCES, path)
    end

    it 'starts empty rather than raising' do
      empty = nil
      expect { empty = manifest.empty? }.to output(/unreadable/i).to_stderr
      expect(empty).to be(true)
    end

    it 'warns to stderr so the resulting full re-check is explainable' do
      expect { described_class.new(path: path, database_ids: database_ids) }
        .to output(/discarding notion sync manifest.*unreadable file/im).to_stderr
    end
  end

  describe 'version guard' do
    it 'discards a manifest written by a future schema version' do
      File.write(path, JSON.generate(
                         'version' => described_class::VERSION + 1,
                         'databases' => { 'data_models' => 'db-models' },
                         'pages' => { 'data_models' => { 'users' => { 'hash' => 'h', 'page_id' => 'p' } } }
                       ))
      expect { expect(manifest).to be_empty }.to output(/schema version/i).to_stderr
    end
  end

  describe 'atomic persistence' do
    it 'writes through AtomicFile so a torn write can never land' do
      allow(Woods::AtomicFile).to receive(:write).and_call_original
      manifest.record(scope: 'data_models', key: 'users', hash: 'h', page_id: 'p')
      manifest.save
      expect(Woods::AtomicFile).to have_received(:write).with(path, kind_of(String))
    end
  end
end
