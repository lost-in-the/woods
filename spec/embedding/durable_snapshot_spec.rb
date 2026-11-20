# frozen_string_literal: true

require 'spec_helper'
require 'json'
require 'tmpdir'
require 'fileutils'
require 'woods'
require 'woods/embedding/indexer'
require 'woods/embedding/fake'
require 'woods/embedding/text_preparer'
require 'woods/index_artifact'
require 'woods/mcp/config_resolver'
require 'woods/resolved_config'
require 'woods/storage/metadata_store'
require 'woods/storage/snapshotter'

# A durable vector store (pgvector, Qdrant) keeps its vectors itself, so an
# embed run has no vector dump to write. It still has to publish woods.json,
# and the metadata dump when metadata is in memory: they are what the packaged
# server reopens the index from.
RSpec.describe Woods::Embedding::Indexer, 'publishing a durable-store snapshot' do
  # The shape pgvector and Qdrant present to the Indexer: #each_id and
  # #delete of their own, #each_entry only as the interface's stub.
  let(:durable_store_class) do
    Class.new do
      include Woods::Storage::VectorStore::Interface

      attr_reader :entries

      def initialize
        @entries = {}
      end

      def store_batch(items)
        items.each { |item| @entries[item[:id]] = item[:vector] }
      end

      def each_id(&block)
        return enum_for(:each_id) unless block

        @entries.keys.each(&block)
      end

      def delete(id)
        @entries.delete(id)
      end

      def count = @entries.size
    end
  end

  let(:output_dir) { Dir.mktmpdir('woods-durable-snapshot') }
  let(:vector_store) { durable_store_class.new }
  let(:metadata_store) { Woods::Storage::MetadataStore::InMemory.new }
  let(:provider) { Woods::Embedding::Provider::Fake.new(dims: 4) }
  let(:secrets) { %w[pw-secret-sentinel user-secret-sentinel db-secret-sentinel key-secret-sentinel] }
  let(:host_config) do
    Woods::Configuration.new.tap do |config|
      config.embedding_provider = :fake
      config.embedding_options = { dims: 4 }
      config.vector_store = :pgvector
      config.vector_store_options = {
        connection: 'postgres://user-secret-sentinel:pw-secret-sentinel@db.example/db-secret-sentinel',
        url: 'https://qdrant.example/?api_key=key-secret-sentinel',
        api_key: 'key-secret-sentinel', password: 'pw-secret-sentinel',
        table: 'woods_vectors', schema: 'search', dimensions: 4
      }
      config.metadata_store = :in_memory
      config.graph_store = :in_memory
    end
  end
  let(:resolved_config) { Woods::ResolvedConfig.from_configuration(host_config, provider: provider) }
  let(:artifact) { Woods::IndexArtifact.new(output_dir) }

  def build_indexer(resolved: resolved_config, metadata: metadata_store)
    described_class.new(provider: provider, text_preparer: Woods::Embedding::TextPreparer.new,
                        vector_store: vector_store, metadata_store: metadata, output_dir: output_dir,
                        resolved_config: resolved)
  end

  def write_unit(identifier, source = "class #{identifier}; end")
    File.write(File.join(output_dir, "#{identifier}.json"),
               JSON.generate('type' => 'model', 'identifier' => identifier,
                             'file_path' => "app/models/#{identifier.downcase}.rb",
                             'source_code' => source, 'source_hash' => Digest::SHA256.hexdigest(source)))
  end

  def dump_dirs
    Dir.glob(File.join(output_dir, 'dumps', '*')).select { |path| File.directory?(path) }
  end

  before { %w[User Post Comment Tag Order].each { |identifier| write_unit(identifier) } }

  after { FileUtils.rm_rf(output_dir) }

  describe 'a full run' do
    it 'writes woods.json and promotes it inside a dump, without a vector dump' do
      build_indexer.index_all

      expect(File).to exist(artifact.config_path)
      expect(File).to exist(artifact.dump_config_path(artifact.latest_dump_path))
      expect(File).not_to exist(artifact.latest_dump_path.join('vectors.bin'))
      expect(Woods::ResolvedConfig.from_hash(artifact.read_config).stores[:vector_store]).to eq(:pgvector)
    end

    it 'dumps the in-memory metadata the server hydrates beside the durable vectors' do
      build_indexer.index_all

      dumped = Woods::Storage::Snapshotter::Metadata.load_or_empty(artifact)
      expect(dumped.all_identifiers).to contain_exactly('User', 'Post', 'Comment', 'Tag', 'Order')
    end

    it 'records only the non-secret options that reopen the store' do
      build_indexer.index_all

      [artifact.config_path, artifact.dump_config_path(artifact.latest_dump_path)].each do |path|
        written = File.read(path)
        secrets.each { |secret| expect(written).not_to include(secret) }
        options = JSON.parse(written).dig('store_options', 'vector_store')
        expect(options.keys).to contain_exactly('table', 'schema', 'dimensions')
      end
    end

    it 'writes no metadata dump for SQLite, which reopens at metadata.sqlite3' do
      sqlite = Woods::Storage::MetadataStore::SQLite.new(database: File.join(output_dir, 'metadata.sqlite3'))
      build_indexer(metadata: sqlite).index_all

      expect(File).to exist(artifact.config_path)
      expect(File).not_to exist(artifact.latest_dump_path.join('metadata.msgpack'))
    end

    it 'replaces the config of an earlier in-memory dump, which would otherwise shadow it' do
      dump_dir = artifact.new_dump_dir(now: Time.utc(2026, 1, 1))
      stale = host_config.dup.tap { |config| config.vector_store = :in_memory }
      artifact.write_dump_config(dump_dir, Woods::ResolvedConfig.from_configuration(stale, provider: provider))
      artifact.promote(dump_dir)

      build_indexer.index_all

      expect(Woods::ResolvedConfig.from_hash(artifact.read_config).stores[:vector_store]).to eq(:pgvector)
    end

    it 'writes nothing without a resolved config' do
      build_indexer(resolved: nil).index_all

      expect(File).not_to exist(artifact.config_path)
      expect(Dir).not_to exist(File.join(output_dir, 'dumps'))
    end

    it 'leaves checkpoint.json unwritten when publishing the snapshot fails' do
      allow_any_instance_of(Woods::IndexArtifact).to receive(:promote).and_raise(Errno::ENOSPC)

      expect { build_indexer.index_all }.to raise_error(Errno::ENOSPC)
      expect(File).not_to exist(File.join(output_dir, 'checkpoint.json'))
    end
  end

  describe 'an incremental run' do
    it 'publishes the snapshot an earlier gem never wrote, without re-embedding' do
      build_indexer.index_all
      # What an earlier gem left: vectors and checkpoint.json, no snapshot.
      FileUtils.rm_rf([artifact.config_path.to_s, artifact.dumps_root.to_s])

      stats = build_indexer(metadata: Woods::Storage::MetadataStore::InMemory.new).index_incremental

      expect(stats[:processed]).to eq(0)
      expect(File).to exist(artifact.config_path)
      expect(Woods::Storage::Snapshotter::Metadata.load_or_empty(artifact).count).to eq(5)
    end

    it 'writes no new dump when nothing changed' do
      build_indexer.index_all
      before_run = dump_dirs

      build_indexer(metadata: Woods::Storage::MetadataStore::InMemory.new).index_incremental

      expect(dump_dirs).to eq(before_run)
    end

    it 'dumps every unit after a run that re-embedded one, unchanged units included' do
      build_indexer.index_all
      write_unit('User', "class User\n  has_many :posts\nend")

      stats = build_indexer(metadata: Woods::Storage::MetadataStore::InMemory.new).index_incremental

      expect(stats[:processed]).to eq(1)
      dumped = Woods::Storage::Snapshotter::Metadata.load_or_empty(artifact)
      expect(dumped.all_identifiers).to contain_exactly('User', 'Post', 'Comment', 'Tag', 'Order')
      expect(dumped.find('User')['source_code']).to include('has_many :posts')
    end

    it 'drops a deleted unit from the metadata dump along with its vector' do
      build_indexer.index_all
      File.unlink(File.join(output_dir, 'Order.json'))

      build_indexer(metadata: Woods::Storage::MetadataStore::InMemory.new).index_incremental

      expect(vector_store.entries).not_to have_key('Order')
      expect(Woods::Storage::Snapshotter::Metadata.load_or_empty(artifact).all_identifiers).not_to include('Order')
    end

    it 'publishes a dump whose metadata changed without a source change' do
      build_indexer.index_all
      unit = JSON.parse(File.read(File.join(output_dir, 'Post.json')))
      File.write(File.join(output_dir, 'Post.json'), JSON.generate(unit.merge('file_path' => 'app/models/moved.rb')))

      build_indexer(metadata: Woods::Storage::MetadataStore::InMemory.new).index_incremental

      dumped = Woods::Storage::Snapshotter::Metadata.load_or_empty(artifact)
      expect(dumped.find('Post')['file_path']).to eq('app/models/moved.rb')
    end
  end

  describe 'the packaged server reading what the run wrote' do
    it 'fails closed naming WOODS_PG_URL under WOODS_REQUIRE_INDEX=1, never pattern-only' do
      build_indexer.index_all

      expect do
        Woods::MCP::ConfigResolver.resolve(Woods::Configuration.new, artifact: artifact,
                                                                     env: { 'WOODS_REQUIRE_INDEX' => '1' })
      end.to raise_error(Woods::MCP::ConfigMismatch, /WOODS_PG_URL/)
    end
  end
end
