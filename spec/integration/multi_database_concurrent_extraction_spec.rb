# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'yaml'
require 'digest'
require 'securerandom'

# Concurrent full extraction of an application whose second database has a
# one-connection pool. Before, workers were sized by the default pool alone: a
# worker waited out `checkout_timeout` on the second pool, its table listing
# came back empty, and the run published a generation without that database's
# tables or table edges.
RSpec.describe 'Concurrent extraction across database pools', :booted_app do
  include IndexComparison

  before(:all) do
    @previous_rails_env = ENV.fetch('RAILS_ENV', nil)
    ENV['RAILS_ENV'] = 'test'
    require 'rails'
    require 'active_record/railtie'
    require 'action_controller/railtie'
    require 'action_mailer/railtie'
    require 'active_job/railtie'
    require 'logger'
    require File.expand_path('../dummy/config/application_config', __dir__)

    @scratch_dir = Dir.mktmpdir('woods_multidatabase_pools')
    @app_root = File.join(@scratch_dir, 'app')
    FileUtils.cp_r(File.expand_path('../dummy', __dir__), @app_root)
    FileUtils.cp_r(File.join(File.expand_path('../fixtures/multi_database', __dir__), '.'), @app_root)
    write_database_config

    unless defined?(WoodsDummyApplication)
      app_class = Class.new(Rails::Application) do
        config.eager_load = false
        config.logger = Logger.new(IO::NULL)
        config.consider_all_requests_local = true
      end
      Object.const_set(:WoodsDummyApplication, app_class)
      WoodsDummyApplication.config.root = @app_root
      WoodsDummyApplication.config.secret_key_base = 'woods-dummy-secret'
      WoodsDummyConfig.apply(WoodsDummyApplication.config, @app_root)
      WoodsDummyApplication.initialize!
    end
    BootedAppRoot.assert!(@app_root)

    ActiveRecord::Base.establish_connection(:primary)
    define_archive_record
    create_tables
    @databases_connected = true
    Rails.application.eager_load!
    release_connections

    require 'woods'
    require 'woods/extractor'
    @original_woods_config = Woods.configuration
    Woods.configuration = Woods::Configuration.new
    Woods.configuration.concurrent_extraction = false
    @control_dir = File.join(@scratch_dir, 'control')
    Woods::Extractor.new(output_dir: @control_dir).extract_all
    release_connections
  end

  after(:all) do
    Woods.configuration = @original_woods_config if defined?(@original_woods_config)
    if @databases_connected
      [PrimaryRecord, BillingRecord, ReportingRecord, ArchiveRecord, ActiveRecord::Base].each(&:remove_connection)
    end
    ENV['RAILS_ENV'] = @previous_rails_env
    FileUtils.rm_rf(@scratch_dir) if @scratch_dir
  end

  before { Woods.configuration.concurrent_extraction = true }

  after do
    Woods.configuration.concurrent_extraction = false
    release_connections
  end

  # The billing database gets a pool of one, and every pool a short checkout
  # timeout, so a starved worker fails in a fraction of a second.
  def write_database_config
    databases = %w[primary billing reporting archive].to_h do |name|
      [name, { 'adapter' => 'sqlite3', 'database' => File.join(@scratch_dir, "#{name}.sqlite3"),
               'pool' => name == 'billing' ? 1 : 5, 'checkout_timeout' => 0.2 }]
    end
    File.write(File.join(@app_root, 'config', 'database.yml'), { 'test' => databases }.to_yaml)
  end

  # A fourth database, through an abstract class only, that one example makes unreachable.
  def define_archive_record
    archive = Object.const_set(:ArchiveRecord, Class.new(ActiveRecord::Base))
    archive.abstract_class = true
    archive.connects_to(database: { writing: :archive })
  end

  def create_tables
    ArchiveRecord.connection.create_table(:notes) { |t| t.string :body }
    PrimaryRecord.connection.create_table(:accounts) { |t| t.string :name }
    BillingRecord.connection.create_table(:accounts) { |t| t.string :name }
    BillingRecord.connection.create_table(:invoices) { |t| t.references :account, foreign_key: true }
    ReportingRecord.connection.create_table(:subscriptions) do |t|
      t.integer :account_id
      t.integer :subscriber_id
    end
  end

  def release_connections
    [ActiveRecord::Base, PrimaryRecord, BillingRecord, ReportingRecord, ArchiveRecord].each do |klass|
      klass.connection_pool.release_connection
    end
  end

  def output_dir(name)
    File.join(@scratch_dir, "#{name}-#{SecureRandom.hex(4)}")
  end

  # The tables, and the second database's model's foreign keys and table edge.
  def schema_facts(dir)
    units = unit_snapshot(dir).values
    invoice = units.find { |unit| unit['type'] == 'model' && unit['identifier'] == 'MultiInvoice' } || {}
    {
      tables: units.select { |unit| unit['type'] == 'database_table' }.map { |unit| unit['identifier'] }.sort,
      foreign_keys: invoice.dig('metadata', 'foreign_keys'),
      table_edges: Array(invoice['dependencies']).select { |edge| edge['type'] == 'database_table' }
    }
  end

  # The marker, the payload directories, and every byte of the current payload.
  def generation_state(dir)
    marker = File.read(File.join(dir, 'generation.json'))
    payload = File.join(dir, JSON.parse(marker).fetch('payload'))
    files = Dir.glob('**/*', base: payload).sort.to_h do |relative|
      path = File.join(payload, relative)
      [relative, File.file?(path) ? Digest::SHA256.file(path).hexdigest : :directory]
    end
    { marker: marker, number: JSON.parse(marker).fetch('number'),
      payloads: Dir.children(File.join(dir, 'payloads')).sort, files: files }
  end

  # Another thread (an application thread, say) holds the second pool's only connection,
  # and, +querying+, keeps reading through it until released.
  # A run leaves its own leases on this thread, so they are released first.
  def while_another_thread_holds_billing(querying: false)
    release_connections
    held = Queue.new
    release = Queue.new
    holder = Thread.new do
      BillingRecord.connection_pool.with_connection do |connection|
        held << :held
        read_until(release, connection) if querying
        release.pop
      end
    rescue StandardError => e
      held << e
    end
    state = held.pop
    raise state if state.is_a?(Exception)

    yield
  ensure
    release << true
    holder&.join
  end

  def read_until(release, connection)
    while release.empty?
      connection.select_value('SELECT 1')
      sleep 0.01
    end
  end

  it 'publishes the sequential tables, foreign keys and table edges while this thread holds the second pool' do
    dir = output_dir('held-by-caller')
    BillingRecord.connection_pool.with_connection do
      Woods::Extractor.new(output_dir: dir).extract_all
    end

    expect(schema_facts(dir)).to eq(schema_facts(@control_dir))
    expect(schema_facts(dir)[:tables]).to include('table:billing.invoices', 'table:billing.accounts')
  end

  # The second database answers its first table listing in the run, and
  # every later checkout for one times out, as when other threads take the
  # pool between reads.
  def time_out_after_first_listing
    connection = BillingRecord.connection_pool.with_connection { |held| held }
    listings = 0
    @timing_out = true
    allow(connection).to receive(:tables).and_wrap_original do |original, *args|
      listings += 1
      raise ActiveRecord::ConnectionTimeoutError, 'could not obtain a connection' if @timing_out && listings > 1

      original.call(*args)
    end
  end

  def refuses_after_a_served_read
    dir = output_dir('served-then-timeout')
    Woods::Extractor.new(output_dir: dir).extract_all
    before = generation_state(dir)
    time_out_after_first_listing

    expect { Woods::Extractor.new(output_dir: dir).extract_all }
      .to raise_error(Woods::ExtractionError, /Database reads failed for /)
    expect(generation_state(dir)).to eq(before)
    dir
  end

  it 'refuses a full run, keeping the previous generation, when a pool that answered a read times out' do
    dir = refuses_after_a_served_read

    @timing_out = false
    release_connections
    Woods::Extractor.new(output_dir: dir).extract_all
    expect(schema_facts(dir)).to eq(schema_facts(@control_dir))
  end

  it 'refuses a sequential full run the same way' do
    Woods.configuration.concurrent_extraction = false
    refuses_after_a_served_read
  end

  it 'publishes, recording the failure, when another thread holds the second pool for the whole run' do
    dir = output_dir('held-elsewhere')
    Woods::Extractor.new(output_dir: dir).extract_all
    before = generation_state(dir)

    while_another_thread_holds_billing { Woods::Extractor.new(output_dir: dir).extract_all }

    expect(generation_state(dir)[:number]).to eq(before[:number] + 1)
    expect(schema_facts(dir)[:tables]).not_to include('table:billing.invoices')
    expect(read_json(dir, 'source_inputs.json')['unverified_scopes']).to include('extractor:database_tables')
  end

  it "publishes when the thread holding the second pool all run queries it, since that read is not the run's" do
    dir = output_dir('held-and-read-elsewhere')
    Woods::Extractor.new(output_dir: dir).extract_all
    before = generation_state(dir)

    while_another_thread_holds_billing(querying: true) { Woods::Extractor.new(output_dir: dir).extract_all }

    expect(generation_state(dir)[:number]).to eq(before[:number] + 1)
    expect(schema_facts(dir)[:tables]).not_to include('table:billing.invoices')
  end

  it 'refuses a sequential full run when a pool that answered a listing then fails to connect' do
    Woods.configuration.concurrent_extraction = false
    dir = output_dir('served-then-refused')
    Woods::Extractor.new(output_dir: dir).extract_all
    before = generation_state(dir)
    connection = BillingRecord.connection_pool.with_connection { |held| held }
    listings = 0
    allow(connection).to receive(:tables).and_wrap_original do |original, *args|
      listings += 1
      raise ActiveRecord::ConnectionNotEstablished, 'too many connections' if listings > 1

      original.call(*args)
    end

    expect { Woods::Extractor.new(output_dir: dir).extract_all }
      .to raise_error(Woods::ExtractionError, /Database reads failed for /)
    expect(generation_state(dir)).to eq(before)
  end

  # The error a stub raises carries no pool on any Rails, as a real checkout timeout before 7.1.
  it "refuses a full run when one table's schema read times out on a pool that listed it" do
    Woods.configuration.concurrent_extraction = false
    dir = output_dir('table-read-timeout')
    Woods::Extractor.new(output_dir: dir).extract_all
    before = generation_state(dir)
    connection = BillingRecord.connection_pool.with_connection { |held| held }
    allow(connection).to receive(:columns).and_wrap_original do |original, name, *args|
      raise ActiveRecord::ConnectionTimeoutError, 'could not obtain a connection' if name.to_s == 'invoices'

      original.call(name, *args)
    end

    expect { Woods::Extractor.new(output_dir: dir).extract_all }
      .to raise_error(Woods::ExtractionError, /Database reads failed for .*database_tables/)
    expect(generation_state(dir)).to eq(before)
  end

  # The model's schema header reads indexes and foreign keys through its own pool.
  def refuses_models_when_billing(reader, error)
    Woods.configuration.concurrent_extraction = false
    dir = output_dir("model-#{reader}-fails")
    Woods::Extractor.new(output_dir: dir).extract_all
    before = generation_state(dir)
    fail_on_invoices(reader, error)

    expect { Woods::Extractor.new(output_dir: dir).extract_all }
      .to raise_error(Woods::ExtractionError, /Database reads failed for .*\bmodels\b/)
    expect(generation_state(dir)).to eq(before)
  end

  def fail_on_invoices(reader, error)
    connection = BillingRecord.connection_pool.with_connection { |held| held }
    allow(connection).to receive(reader).and_wrap_original do |original, name, *args|
      raise error if name.to_s == 'invoices'

      original.call(name, *args)
    end
  end

  it "refuses a full run when the database refuses a model's index read" do
    refuses_models_when_billing(:indexes, ActiveRecord::StatementInvalid.new('permission denied'))
  end

  it "refuses a full run when a model's foreign key read times out on a pool that answered" do
    refuses_models_when_billing(:foreign_keys, ActiveRecord::ConnectionTimeoutError.new('no connection'))
  end

  it 'refuses a full run when listing the second database raises' do
    dir = output_dir('listing-raises')
    Woods::Extractor.new(output_dir: dir).extract_all
    before = generation_state(dir)
    connection = BillingRecord.connection_pool.with_connection { |held| held }
    allow(connection).to receive(:tables).and_raise(ActiveRecord::StatementInvalid, 'listing refused')

    expect { Woods::Extractor.new(output_dir: dir).extract_all }
      .to raise_error(Woods::ExtractionError, /Database reads failed for .*database_tables/)
    expect(generation_state(dir)).to eq(before)
  end

  it 'publishes, recording the failure, when a database cannot be connected for any read' do
    dir = output_dir('unreachable')
    Woods::Extractor.new(output_dir: dir).extract_all
    before = generation_state(dir)
    release_connections
    allow(ArchiveRecord.connection_pool).to receive(:checkout)
      .and_raise(ActiveRecord::ConnectionNotEstablished, 'connection refused')

    Woods::Extractor.new(output_dir: dir).extract_all

    expect(generation_state(dir)[:number]).to eq(before[:number] + 1)
    expect(schema_facts(dir)[:tables]).to eq(schema_facts(@control_dir)[:tables] - ['table:archive.notes'])
    expect(read_json(dir, 'source_inputs.json')['unverified_scopes']).to include('extractor:database_tables')
  end
end
