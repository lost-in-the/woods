# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# A real Active Record pool, not a double for its size: the WDS-100 review
# reproduced a worker waiting out checkout_timeout while the calling thread
# sat in join holding the pool's only connection.
RSpec.describe 'Concurrent extraction against a real connection pool', :booted_app do
  before(:context) do
    require 'active_record'
    require 'woods'
    require 'woods/extractor'
  end

  let(:tmpdir) { Dir.mktmpdir('woods_pool') }
  let(:extractor) { Woods::Extractor.new(output_dir: File.join(tmpdir, 'out')) }

  # One extractor family that really checks out a connection and queries.
  let(:querying_extractor) do
    Class.new do
      def self.queries = (@queries ||= Queue.new)

      def extract_all
        ActiveRecord::Base.connection_pool.with_connection do |connection|
          self.class.queries << connection.select_value('SELECT 1')
          sleep 0.02
        end
        []
      end
    end
  end

  def run_concurrent(families)
    stub_const('Woods::Extractor::EXTRACTORS', families)
    allow(Woods::ModelNameCache).to receive_messages(model_names: [], model_names_regex: /(?!)/)
    extractor.instance_variable_set(:@results, {})
    extractor.instance_variable_set(:@extractors, {})
    extractor.send(:extract_all_concurrent)
  end

  before do
    stub_const('Rails', double('Rails', logger: double('Logger').as_null_object, root: Pathname.new(tmpdir)))
  end

  after do
    ActiveRecord::Base.connection_pool.release_connection if ActiveRecord::Base.connected?
    ActiveRecord::Base.remove_connection
    FileUtils.rm_rf(tmpdir)
    Woods.configuration = Woods::Configuration.new
  end

  def establish(pool:)
    ActiveRecord::Base.establish_connection(adapter: 'sqlite3', database: ':memory:', pool: pool, checkout_timeout: 0.1)
  end

  it 'runs database-free extractors when Active Record is loaded but no connection is configured' do
    ActiveRecord::Base.remove_connection
    db_free = Class.new { def extract_all = [] }

    expect { run_concurrent(services: db_free, jobs: Class.new(db_free)) }.not_to raise_error
  end

  it 'runs on the calling thread when that thread holds the pool\'s only connection (WDS-100)' do
    establish(pool: 1)
    ActiveRecord::Base.connection_pool.with_connection do
      expect { run_concurrent(models: querying_extractor) }.not_to raise_error
    end
    expect(querying_extractor.queries.size).to eq(1)
  end

  it 'starts no more workers than the connections nobody holds, and returns each one' do
    establish(pool: 3)
    families = { models: querying_extractor, controllers: querying_extractor, jobs: querying_extractor,
                 mailers: querying_extractor }
    pool = ActiveRecord::Base.connection_pool
    pool.with_connection do
      expect(extractor.send(:concurrent_extraction_workers, families.size)).to eq(2)
      expect { run_concurrent(families) }.not_to raise_error
      expect(pool.stat[:busy]).to eq(1)
    end
    expect(querying_extractor.queries.size).to eq(4)
  end
end
