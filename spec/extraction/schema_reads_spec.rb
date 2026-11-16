# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'woods/extraction/schema_reads'

RSpec.describe Woods::Extraction::SchemaReads do
  let(:root) { Pathname.new(Dir.mktmpdir) }
  let(:config) { double('DbConfig', env_name: 'development', name: 'primary', schema_cache_path: nil) }
  let(:pool) { double('Pool', db_config: config, connected?: true) }
  let(:cache) { double('SchemaCache', clear!: nil) }
  let(:connection) { double('Connection', pool: pool, schema_cache: cache) }

  before do
    stub_const('Rails', double('Rails', root: root))
    allow(pool).to receive(:with_connection).and_yield(connection)
    allow(cache).to receive(:data_source_exists?).and_return(true)
  end

  after { FileUtils.rm_rf(root) }

  describe '.read' do
    it 'asks the connection once per database, kind and table inside a run' do
      allow(connection).to receive(:columns).with('widgets').and_return([:id])

      described_class.with do
        2.times { expect(described_class.read(connection, :columns, 'widgets')).to eq([:id]) }
      end

      expect(connection).to have_received(:columns).once
    end

    it 'asks the connection every time outside a run' do
      allow(connection).to receive(:columns).with('widgets').and_return([:id])

      2.times { described_class.read(connection, :columns, 'widgets') }

      expect(connection).to have_received(:columns).twice
    end
  end

  describe '.runtime_cache' do
    it "answers Active Record's cache inside a run when no dump could be loaded" do
      described_class.with { expect(described_class.runtime_cache(connection, 'widgets')).to be(cache) }
    end

    it 'answers nothing outside a run, where nothing vouches for the cache' do
      expect(described_class.runtime_cache(connection, 'widgets')).to be_nil
    end

    it 'answers nothing for a table the cache does not know' do
      allow(cache).to receive(:data_source_exists?).with('ignored').and_return(false)

      described_class.with { expect(described_class.runtime_cache(connection, 'ignored')).to be_nil }
    end

    it 'answers nothing when a dump file sits under db/' do
      FileUtils.mkdir_p(root.join('db'))
      File.write(root.join('db/schema_cache.yml'), "--- {}\n")

      described_class.with { expect(described_class.runtime_cache(connection, 'widgets')).to be_nil }
    end

    it 'answers nothing when the database config names a dump' do
      allow(config).to receive(:schema_cache_path).and_return('tmp/schema_cache.yml')

      described_class.with { expect(described_class.runtime_cache(connection, 'widgets')).to be_nil }
    end

    it 'answers nothing when SCHEMA_CACHE names a dump' do
      stub_const('ENV', ENV.to_h.merge('SCHEMA_CACHE' => 'tmp/cache.yml'))

      described_class.with { expect(described_class.runtime_cache(connection, 'widgets')).to be_nil }
    end
  end

  describe '.with' do
    let(:handler) { double('ConnectionHandler', connection_pool_list: [pool]) }

    before { stub_const('ActiveRecord::Base', double('Base', connection_handler: handler)) }

    it "empties each connected pool's schema cache when a run starts, so a long-lived process reads the new schema" do
      described_class.with { nil }

      expect(cache).to have_received(:clear!).once
    end

    it 'leaves a cache alone when a dump could be loaded, since clearing would drop the dump' do
      FileUtils.mkdir_p(root.join('db'))
      File.write(root.join('db/schema_cache.yml'), "--- {}\n")

      described_class.with { nil }

      expect(cache).not_to have_received(:clear!)
    end

    it 'leaves a pool that is not connected alone' do
      allow(pool).to receive(:connected?).and_return(false)

      described_class.with { nil }

      expect(cache).not_to have_received(:clear!)
    end

    it 'clears once for nested runs' do
      described_class.with { described_class.with { nil } }

      expect(cache).to have_received(:clear!).once
    end
  end
end
