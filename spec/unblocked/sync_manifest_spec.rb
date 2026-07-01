# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'json'
require 'woods'
require 'woods/unblocked/sync_manifest'

RSpec.describe Woods::Unblocked::SyncManifest do
  around do |example|
    Dir.mktmpdir do |dir|
      @dir = dir
      example.run
    end
  end

  let(:path) { File.join(@dir, 'unblocked_sync_manifest.json') }
  let(:collection_id) { 'col-1' }

  subject(:manifest) { described_class.new(path: path, collection_id: collection_id) }

  describe 'a fresh manifest' do
    it 'is empty when no file exists' do
      expect(manifest).to be_empty
    end

    it 'treats every uri as changed' do
      expect(manifest.unchanged?('uri-a', 'hash-1')).to be(false)
    end

    it 'has no document_id for an unknown uri' do
      expect(manifest.document_id_for('uri-a')).to be_nil
    end
  end

  describe '#record and #unchanged?' do
    it 'reports a recorded uri+hash as unchanged' do
      manifest.record(uri: 'uri-a', hash: 'hash-1', document_id: 'doc-1')
      expect(manifest.unchanged?('uri-a', 'hash-1')).to be(true)
    end

    it 'reports a recorded uri with a different hash as changed' do
      manifest.record(uri: 'uri-a', hash: 'hash-1', document_id: 'doc-1')
      expect(manifest.unchanged?('uri-a', 'hash-2')).to be(false)
    end

    it 'exposes the stored document_id' do
      manifest.record(uri: 'uri-a', hash: 'hash-1', document_id: 'doc-1')
      expect(manifest.document_id_for('uri-a')).to eq('doc-1')
    end

    it 'is no longer empty after a record' do
      manifest.record(uri: 'uri-a', hash: 'hash-1', document_id: 'doc-1')
      expect(manifest).not_to be_empty
    end
  end

  describe '#stale_uris' do
    before do
      manifest.record(uri: 'keep', hash: 'h', document_id: 'd1')
      manifest.record(uri: 'gone', hash: 'h', document_id: 'd2')
    end

    it 'returns recorded uris absent from the current set' do
      expect(manifest.stale_uris(['keep'])).to contain_exactly('gone')
    end

    it 'returns nothing when every recorded uri is still present' do
      expect(manifest.stale_uris(%w[keep gone])).to eq([])
    end
  end

  describe '#forget' do
    it 'removes a uri so it is no longer stale or known' do
      manifest.record(uri: 'gone', hash: 'h', document_id: 'd')
      manifest.forget('gone')
      expect(manifest.document_id_for('gone')).to be_nil
      expect(manifest.stale_uris([])).to eq([])
    end
  end

  describe '#save and reload' do
    it 'round-trips records through the JSON file' do
      manifest.record(uri: 'uri-a', hash: 'hash-1', document_id: 'doc-1')
      manifest.save

      reloaded = described_class.new(path: path, collection_id: collection_id)
      expect(reloaded.unchanged?('uri-a', 'hash-1')).to be(true)
      expect(reloaded.document_id_for('uri-a')).to eq('doc-1')
    end

    it 'creates the parent directory if missing' do
      nested = File.join(@dir, 'sub', 'dir', 'manifest.json')
      m = described_class.new(path: nested, collection_id: collection_id)
      m.record(uri: 'u', hash: 'h', document_id: 'd')
      expect { m.save }.not_to raise_error
      expect(File.exist?(nested)).to be(true)
    end
  end

  describe 'collection guard' do
    it 'starts empty when the persisted collection_id differs' do
      described_class.new(path: path, collection_id: 'OLD').tap do |old|
        old.record(uri: 'uri-a', hash: 'hash-1', document_id: 'doc-1')
        old.save
      end

      fresh = described_class.new(path: path, collection_id: 'NEW')
      expect(fresh).to be_empty
      expect(fresh.unchanged?('uri-a', 'hash-1')).to be(false)
    end

    it 'loads normally when the persisted collection_id matches' do
      described_class.new(path: path, collection_id: collection_id).tap do |m|
        m.record(uri: 'uri-a', hash: 'hash-1', document_id: 'doc-1')
        m.save
      end

      reloaded = described_class.new(path: path, collection_id: collection_id)
      expect(reloaded.unchanged?('uri-a', 'hash-1')).to be(true)
    end
  end

  describe 'corrupt manifest file' do
    it 'starts empty rather than raising' do
      File.write(path, 'not valid json {{{')
      expect(manifest).to be_empty
    end

    it 'warns to stderr so the resulting full re-push is explainable' do
      File.write(path, 'not valid json {{{')
      expect { described_class.new(path: path, collection_id: collection_id) }
        .to output(/unparseable/i).to_stderr
    end
  end

  describe 'version guard' do
    it 'discards a manifest written by a future schema version' do
      File.write(path, JSON.generate(
                         'version' => described_class::VERSION + 1,
                         'collection_id' => collection_id,
                         'documents' => { 'uri-a' => { 'hash' => 'h', 'document_id' => 'd' } }
                       ))
      expect(manifest).to be_empty
    end
  end

  describe 'collection mismatch warning' do
    it 'warns to stderr when discarding a foreign-collection manifest' do
      described_class.new(path: path, collection_id: 'OLD').tap do |old|
        old.record(uri: 'u', hash: 'h', document_id: 'd')
        old.save
      end

      expect { described_class.new(path: path, collection_id: 'NEW') }
        .to output(/collection/i).to_stderr
    end
  end
end
