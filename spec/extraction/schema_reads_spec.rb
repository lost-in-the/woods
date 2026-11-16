# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'woods/extraction/schema_reads'

RSpec.describe Woods::Extraction::SchemaReads do
  let(:root) { Pathname.new(Dir.mktmpdir) }
  let(:config) { double('DbConfig', env_name: 'development', name: 'primary', schema_cache_path: nil) }
  # Rails 7.1 and later: the cache lives on the pool config's schema reflection.
  let(:reflection) { double('SchemaReflection', clear!: nil) }
  let(:pool) { double('Pool', db_config: config, schema_reflection: reflection) }
  let(:cache) { double('SchemaCache') }
  let(:connection) { double('Connection', pool: pool, schema_cache: cache) }
  let(:pools) { [pool] }
  let(:handler) { double('ConnectionHandler') }
  let(:active_record_version) { '8.0.0' }

  before do
    stub_const('Rails', double('Rails', root: root))
    version = Gem::Version.new(active_record_version)
    stub_const('ActiveRecord', Module.new { define_singleton_method(:version) { version } })
    stub_const('ActiveRecord::Base', double('Base', connection_handler: handler))
    allow(handler).to receive(:connection_pool_list) { |*_role| pools }
    allow(cache).to receive(:data_source_exists?).and_return(true)
  end

  after { FileUtils.rm_rf(root) }

  def write_dump(dir = root.join('db'))
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, 'schema_cache.yml'), "--- {}\n")
  end

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

    it 'keeps two databases apart when they hold a table of the same name' do
      other_config = double('DbConfig', env_name: 'development', name: 'animals', schema_cache_path: nil)
      other = double('Connection', pool: double('Pool', db_config: other_config))
      allow(connection).to receive(:columns).with('items').and_return([:id])
      allow(other).to receive(:columns).with('items').and_return([:code])

      described_class.with do
        expect(described_class.read(connection, :columns, 'items')).to eq([:id])
        expect(described_class.read(other, :columns, 'items')).to eq([:code])
      end
    end
    it 'keeps two pools apart when their configurations share a name, as establish_connection hashes do' do
      same_labels = double('DbConfig', env_name: 'development', name: 'primary', schema_cache_path: nil)
      other = double('Connection', pool: double('Pool', db_config: same_labels))
      allow(connection).to receive(:columns).with('items').and_return([:id])
      allow(other).to receive(:columns).with('items').and_return([:code])

      described_class.with do
        expect(described_class.read(connection, :columns, 'items')).to eq([:id])
        expect(described_class.read(other, :columns, 'items')).to eq([:code])
      end
    end

    it 'lets concurrent misses of one read wait for a single query' do
      started = Queue.new
      release = Queue.new
      calls = 0
      allow(connection).to receive(:foreign_keys).with('widgets') do
        calls += 1
        started << true
        release.pop
        [:fk]
      end

      workers = []
      described_class.with do
        workers << Thread.new { described_class.read(connection, :foreign_keys, 'widgets') }
        started.pop
        workers << Thread.new { described_class.read(connection, :foreign_keys, 'widgets') }
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
        sleep 0.01 until workers[1].status == 'sleep' || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        # One release per worker, so a regression that queries twice fails on the count instead of hanging.
        2.times { release << true }
        expect(workers.map { |worker| worker.join(5)&.value }).to eq([[:fk], [:fk]])
      ensure
        2.times { release << true }
        workers.each { |worker| worker.join(1) || worker.kill }
      end

      expect(calls).to eq(1)
    end

    it 'reads again after a read that raised' do
      attempts = 0
      allow(connection).to receive(:indexes).with('widgets') do
        attempts += 1
        raise StandardError, 'lost connection' if attempts == 1

        [:index]
      end

      described_class.with do
        expect { described_class.read(connection, :indexes, 'widgets') }.to raise_error(StandardError)
        expect(described_class.read(connection, :indexes, 'widgets')).to eq([:index])
      end
    end
  end

  describe '.runtime_cache' do
    it "answers Active Record's cache inside a run for a pool the run emptied" do
      described_class.with { expect(described_class.runtime_cache(connection, 'widgets')).to be(cache) }
    end

    it 'answers nothing outside a run, where nothing vouches for the cache' do
      expect(described_class.runtime_cache(connection, 'widgets')).to be_nil
    end

    it 'answers nothing for a table the cache does not know' do
      allow(cache).to receive(:data_source_exists?).with('ignored').and_return(false)

      described_class.with { expect(described_class.runtime_cache(connection, 'ignored')).to be_nil }
    end

    it 'answers nothing for a pool the handler did not list, such as another role before Rails 7.2' do
      allow(handler).to receive(:connection_pool_list).and_return([])

      described_class.with { expect(described_class.runtime_cache(connection, 'widgets')).to be_nil }
    end

    it 'answers nothing for a pool whose cache could not be emptied' do
      allow(reflection).to receive(:clear!).and_raise(StandardError, 'boom')

      described_class.with { expect(described_class.runtime_cache(connection, 'widgets')).to be_nil }
    end

    it 'answers nothing when listing the pools fails, as under a raising deprecation' do
      allow(handler).to receive(:connection_pool_list).and_raise(StandardError, 'deprecated')

      described_class.with { expect(described_class.runtime_cache(connection, 'widgets')).to be_nil }
    end

    it 'answers nothing when a dump file sits under db/' do
      write_dump

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
    it "empties each listed pool's schema cache when a run starts, so a long-lived process reads the new schema" do
      described_class.with { nil }

      expect(reflection).to have_received(:clear!).once
    end

    it 'empties a pool without checking out a connection, connected or not' do
      allow(pool).to receive(:with_connection)
      allow(pool).to receive(:connected?).and_return(false)

      described_class.with { nil }

      expect(reflection).to have_received(:clear!).once
      expect(pool).not_to have_received(:with_connection)
    end

    context 'before Rails 7.1' do
      let(:active_record_version) { '7.0.8' }

      it "empties the pool's own cache before Rails 7.1, and passes over one never built" do
        old_cache = double('SchemaCache', clear!: nil)
        old_pool = double('Pool', db_config: config, schema_cache: old_cache)
        unused = double('Pool', db_config: config, schema_cache: nil)
        allow(handler).to receive(:connection_pool_list).with(no_args).and_return([old_pool, unused])
        used = double('Connection', pool: old_pool, schema_cache: old_cache)
        fresh = double('Connection', pool: unused, schema_cache: cache)
        allow(old_cache).to receive(:data_source_exists?).and_return(true)

        described_class.with do
          expect(described_class.runtime_cache(used, 'widgets')).to be(old_cache)
          expect(described_class.runtime_cache(fresh, 'widgets')).to be(cache)
        end
        expect(old_cache).to have_received(:clear!).once
      end
    end

    it 'asks Rails 7.1 and later for every role, which also keeps 7.1 from warning on each run' do
      described_class.with { nil }

      expect(handler).to have_received(:connection_pool_list).with(:all)
    end

    it 'asks a Rails 6.0 handler, whose list takes no role, for its pools' do
      six = Class.new do
        def initialize(pools) = @pools = pools
        def connection_pool_list = @pools
      end.new(pools)
      stub_const('ActiveRecord::Base', double('Base', connection_handler: six))

      described_class.with { nil }

      expect(reflection).to have_received(:clear!).once
    end

    it 'goes on to the next pool when one fails' do
      broken = double('Pool', db_config: config)
      allow(broken).to receive(:schema_reflection).and_raise(StandardError, 'boom')
      allow(handler).to receive(:connection_pool_list).and_return([broken, pool])

      described_class.with { expect(described_class.runtime_cache(connection, 'widgets')).to be(cache) }
    end

    it 'leaves a cache alone when a dump could be loaded, since clearing would drop the dump' do
      write_dump

      described_class.with { nil }

      expect(reflection).not_to have_received(:clear!)
    end

    it 'judges each configuration on its own when two share a name but one names a dump' do
      plain = double('Pool', db_config: config, schema_reflection: reflection)
      dumped_config = double('DbConfig', env_name: 'development', name: 'primary',
                                         schema_cache_path: '/elsewhere/legacy_cache.yml')
      dumped_reflection = double('SchemaReflection', clear!: nil)
      dumped = double('Pool', db_config: dumped_config, schema_reflection: dumped_reflection)
      allow(handler).to receive(:connection_pool_list).and_return([plain, dumped])

      described_class.with { nil }

      expect(reflection).to have_received(:clear!).once
      expect(dumped_reflection).not_to have_received(:clear!)
    end

    it 'leaves a cache alone when the dump sits in a db directory the application moved' do
      write_dump(root.join('database'))
      stub_const('ActiveRecord::Tasks::DatabaseTasks', double('DatabaseTasks', db_dir: 'database'))

      described_class.with { nil }

      expect(reflection).not_to have_received(:clear!)
    end

    it 'leaves every cache alone in an application without a root' do
      stub_const('Rails', double('Rails', root: nil))

      described_class.with { nil }

      expect(reflection).not_to have_received(:clear!)
    end

    it 'clears once for nested runs' do
      described_class.with { described_class.with { nil } }

      expect(reflection).to have_received(:clear!).once
    end

    it 'forgets the emptied pools when the run ends' do
      described_class.with { nil }

      expect(described_class.runtime_cache(connection, 'widgets')).to be_nil
    end
  end
end
