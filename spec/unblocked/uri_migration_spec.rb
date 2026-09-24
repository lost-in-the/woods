# frozen_string_literal: true

require 'spec_helper'
require 'woods'
require 'woods/unblocked/exporter'
require 'tmpdir'
require 'stringio'

RSpec.describe 'Unblocked scoped URI migration' do
  let(:repo) { 'https://github.com/example/app' }
  let(:config) do
    instance_double(Woods::Configuration, unblocked_collection_id: 'ours', unblocked_repo_url: repo,
                                          unblocked_api_token: 'offline-test')
  end
  let(:units) do
    (1..12).map do |number|
      { 'identifier' => "Model#{number}", 'type' => 'model',
        'file_path' => "app/models/model#{number}.rb", 'metadata' => {} }
    end
  end
  let(:reader) do
    Struct.new(:branch, :units) do
      def manifest
        { 'git_branch' => branch }
      end

      def each_unit
        units
      end

      def with_pinned_generation
        yield
      end
    end.new('main', units)
  end
  let(:remote) { {} }
  let(:client) do
    instance_double(Woods::Unblocked::Client).tap do |value|
      allow(value).to receive(:all_documents) do |collection_id:|
        remote.values.select { |document| collection_id.nil? || document['collectionId'] == collection_id }
      end
      sequence = 0
      allow(value).to receive(:put_document) do |collection_id:, uri:, title:, body:|
        remote[uri] = { 'id' => remote.dig(uri, 'id') || "document-#{sequence += 1}", 'uri' => uri,
                        'collectionId' => collection_id, 'title' => title, 'body' => body }
      end
      allow(value).to receive(:delete_document) do |document_id:|
        remote.delete_if { |_uri, document| document['id'] == document_id }
        {}
      end
    end
  end

  around do |example|
    Dir.mktmpdir do |directory|
      @directory = directory
      example.run
    end
  end

  def run_sync(**options)
    Woods::Unblocked::Exporter.new(index_dir: @directory, config: config, reader: reader,
                                   client: client, output: StringIO.new, **options).sync_all
  end

  def seed_legacy
    run_sync
    manifest_path = File.join(@directory, 'unblocked_sync_manifest.json')
    owned = remote.to_h do |uri, document|
      hash = Digest::SHA256.hexdigest("#{document['title']}\n#{document['body']}")
      [uri, { 'hash' => hash, 'document_id' => document['id'] }]
    end
    File.write(manifest_path, JSON.generate('version' => 1, 'collection_id' => 'ours', 'documents' => owned))
  end

  it 'keeps independent branch scopes when one manifest is reused' do
    expect(run_sync[:complete]).to be(true)
    reader.branch = 'develop'
    expect(run_sync[:complete]).to be(true)
    expect(remote.size).to eq(24)
    reader.branch = 'main'
    expect(run_sync[:skipped]).to eq(12)
    expect(remote.size).to eq(24)
    expect(client).not_to have_received(:delete_document)
  end

  it 'migrates proven legacy ownership and converges on a repeated run without a force purge' do
    seed_legacy
    reader.branch = 'develop'
    result = run_sync(migrate_from_ref: 'main')
    expect(result[:complete]).to be(true)
    expect(result[:deleted]).to eq(12)
    expect(remote.size).to eq(12)
    expect(remote.keys).to all(include('/blob/develop/'))
    expect(run_sync[:skipped]).to eq(12)
    expect(remote.size).to eq(12)
  end

  it 'previews migration without writing remotely or changing the manifest' do
    seed_legacy
    reader.branch = 'develop'
    before = File.binread(File.join(@directory, 'unblocked_sync_manifest.json'))
    count = remote.size
    result = run_sync(migrate_from_ref: 'main', dry_run: true)
    expect(result[:migration].size).to eq(12)
    expect(result[:dry_run]).to be(true)
    expect(remote.size).to eq(count)
    expect(File.binread(File.join(@directory, 'unblocked_sync_manifest.json'))).to eq(before)
  end

  it 'does not claim ownership of unrelated documents on a missing-manifest sync' do
    remote['https://example.test/notes'] = { 'id' => 'foreign', 'uri' => 'https://example.test/notes',
                                             'collectionId' => 'ours' }
    expect(run_sync[:complete]).to be(true)
    expect(remote).to have_key('https://example.test/notes')
    expect(client).not_to have_received(:delete_document)
  end

  it 'does not delete legacy remote-adopted records with no successful write fingerprint' do
    seed_legacy
    manifest_path = File.join(@directory, 'unblocked_sync_manifest.json')
    data = JSON.parse(File.read(manifest_path))
    data['documents'].each_value { |entry| entry['hash'] = nil }
    File.write(manifest_path, JSON.generate(data))
    reader.branch = 'develop'
    result = run_sync(migrate_from_ref: 'main')
    expect(result[:complete]).to be(false)
    expect(result[:errors].join).to match(/ownership/i)
    expect(client).not_to have_received(:delete_document)
    expect(remote.keys.count { |uri| uri.include?('/blob/main/') }).to eq(12)
  end

  it 'encodes branch delimiters without turning the file path into a fragment or query' do
    reader.branch = 'feature/a#b?c%'
    run_sync
    parsed = URI(remote.keys.first)
    expect(parsed.fragment).to be_nil
    expect(parsed.query).to be_nil
    expect(parsed.path).to include('feature/a%23b%3Fc%25/app/models/')
  end
  it 'refuses cross-collection URI collisions without moving or deleting the remote document' do
    uri = "#{repo}/blob/main/app/models/model1.rb"
    remote[uri] = { 'id' => 'foreign', 'uri' => uri, 'collectionId' => 'another' }
    result = run_sync
    expect(result[:complete]).to be(false)
    expect(result[:errors].join).to include('different remote collection')
    expect(remote[uri]['collectionId']).to eq('another')
    expect(client).not_to have_received(:delete_document)
  end

  it 'resumes a partial delete failure without re-uploading successful replacements' do
    seed_legacy
    reader.branch = 'develop'
    count = 0
    allow(client).to receive(:delete_document) do |document_id:|
      count += 1
      raise IOError, 'interrupted' if count == 4

      remote.delete_if { |_uri, document| document['id'] == document_id }
    end
    result = run_sync(migrate_from_ref: 'main')
    expect(result[:complete]).to be(false)
    expect(remote.size).to eq(21)
    result = run_sync
    expect(result[:complete]).to be(true)
    expect(result[:skipped]).to eq(12)
    expect(result[:deleted]).to eq(9)
    expect(remote.size).to eq(12)
  end

  it 'retains every old copy when a replacement upload fails and retries later' do
    seed_legacy
    reader.branch = 'develop'
    allow(client).to receive(:put_document).with(hash_including(uri: /develop/)).and_raise(IOError, 'offline')
    result = run_sync(migrate_from_ref: 'main')
    expect(result[:complete]).to be(false)
    expect(remote.size).to eq(12)
    expect(client).not_to have_received(:delete_document)
  end

  it 'refuses cleanup when a remote source identity no longer matches its receipt' do
    seed_legacy
    first = remote.values.first
    first['id'] = 'replaced-by-someone-else'
    reader.branch = 'develop'
    result = run_sync(migrate_from_ref: 'main')
    expect(result[:complete]).to be(false)
    expect(result[:errors].join).to include('identity/collection changed')
    expect(remote.values).to include(first)
  end

  it 'refuses remote operations with a corrupt manifest instead of discarding deletion ownership' do
    seed_legacy
    File.write(File.join(@directory, 'unblocked_sync_manifest.json'), '{')
    expect { run_sync }.to raise_error(Woods::ConfigurationError, /manifest needs recovery/)
    expect(remote.size).to eq(12)
  end

  it 'does not delete old copies when successful replacement receipts cannot be persisted' do
    seed_legacy
    reader.branch = 'develop'
    allow(Woods::AtomicFile).to receive(:write).and_raise(IOError, 'disk full')
    expect { run_sync(migrate_from_ref: 'main') }.to raise_error(IOError, 'disk full')
    expect(client).not_to have_received(:delete_document)
    expect(remote.size).to eq(24)
  end

  it 'reads the index branch inside the same pin as the unit enumeration' do
    pinned = false
    allow(reader).to receive(:with_pinned_generation) do |&block|
      pinned = true
      block.call
    ensure
      pinned = false
    end
    allow(reader).to receive(:manifest) do
      raise 'unpinned branch read' unless pinned

      { 'git_branch' => 'pinned' }
    end
    expect(run_sync[:complete]).to be(true)
    expect(remote.keys).to all(include('/blob/pinned/'))
  end
  it 're-uploads a lost migration replacement before retiring its source on resume' do
    seed_legacy
    reader.branch = 'develop'
    fail_delete = true
    allow(client).to receive(:delete_document) do |document_id:|
      raise IOError, 'pause cleanup' if fail_delete

      remote.delete_if { |_uri, document| document['id'] == document_id }
    end
    expect(run_sync(migrate_from_ref: 'main')[:complete]).to be(false)
    replacement = "#{repo}/blob/develop/app/models/model1.rb"
    remote.delete(replacement)
    fail_delete = false
    result = run_sync
    expect(result[:complete]).to be(true)
    expect(result[:synced]).to eq(1)
    expect(remote.size).to eq(12)
    expect(remote).to have_key(replacement)
  end

  it 'refuses ordinary stale cleanup after the remote document moves collections' do
    run_sync
    uri = "#{repo}/blob/main/app/models/model1.rb"
    remote[uri]['collectionId'] = 'another'
    reader.units = units.drop(1)
    result = run_sync
    expect(result[:complete]).to be(false)
    expect(result[:errors].join).to include('identity/collection changed')
    expect(remote).to have_key(uri)
    expect(client).not_to have_received(:delete_document)
  end
  it 'preserves ambiguous old bare-file ownership when new siblings change the primary URI' do
    beta = { 'identifier' => 'Beta', 'type' => 'lib', 'file_path' => 'lib/shared.rb', 'metadata' => {} }
    reader.units = [beta]
    run_sync
    reader.branch = 'develop'
    alpha = beta.merge('identifier' => 'Alpha', 'dependents' => ['One'])
    others = (1..49).map do |number|
      beta.merge('identifier' => "Other#{number}", 'file_path' => "lib/other#{number}.rb", 'dependents' => ['One'])
    end
    reader.units = [alpha, *others, beta]
    result = run_sync(migrate_from_ref: 'main')
    expect(result[:complete]).to be(false)
    expect(result[:errors].join).to include('unambiguous current replacement')
    expect(remote).to have_key("#{repo}/blob/main/lib/shared.rb")
  end

  it 'migrates a previously owned unit that has fallen below the ordinary partial selection cap' do
    beta = { 'identifier' => 'Beta', 'type' => 'lib', 'file_path' => 'lib/beta.rb', 'metadata' => {} }
    reader.units = [beta]
    run_sync
    reader.branch = 'develop'
    others = (1..50).map do |number|
      beta.merge('identifier' => "Other#{number}", 'file_path' => "lib/other#{number}.rb", 'dependents' => ['One'])
    end
    reader.units = [*others, beta]
    result = run_sync(migrate_from_ref: 'main')
    expect(result[:complete]).to be(true)
    expect(remote).to have_key("#{repo}/blob/develop/lib/beta.rb")
    expect(remote).not_to have_key("#{repo}/blob/main/lib/beta.rb")
  end
  it 'does not retain an empty migration that prevents later source selection' do
    expect(run_sync(migrate_from_ref: 'absent')[:complete]).to be(true)
    expect(run_sync(migrate_from_ref: 'another-absent')[:complete]).to be(true)
    payload = JSON.parse(File.read(File.join(@directory, 'unblocked_sync_manifest.json')))
    expect(payload.fetch('scopes').values).to all(satisfy { |scope| !scope.key?('migration') })
  end
end
