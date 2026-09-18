# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'json'
require 'fileutils'

# Separate process: boot a disposable copy of the dummy app with three real
# SQLite connections. The overlay leaves the ordinary single-database dummy
# and its differential mutation corpus unchanged (B-177).
RSpec.describe 'Booted multi-database extraction', :booted_app do
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

    @scratch_dir = Dir.mktmpdir('woods_multidatabase')
    @app_root = File.join(@scratch_dir, 'app')
    FileUtils.cp_r(File.expand_path('../dummy', __dir__), @app_root)
    FileUtils.cp_r(File.join(File.expand_path('../fixtures/multi_database', __dir__), '.'), @app_root)
    @previous_database_dir = ENV.fetch('WOODS_MULTIDATABASE_DIR', nil)
    ENV['WOODS_MULTIDATABASE_DIR'] = @scratch_dir

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
    create_tables
    @databases_connected = true
    Rails.application.eager_load!

    require 'woods'
    require 'woods/extractor'
    @original_woods_config = Woods.configuration
    Woods.configuration = Woods::Configuration.new
    Woods.configuration.concurrent_extraction = false
    @output_dir = File.join(@scratch_dir, 'index')
    Woods::Extractor.new(output_dir: @output_dir).extract_all
  end

  after(:all) do
    Woods.configuration = @original_woods_config if defined?(@original_woods_config)
    if @databases_connected
      [PrimaryRecord, BillingRecord, ReportingRecord, ActiveRecord::Base].each(&:remove_connection)
    end
    ENV['RAILS_ENV'] = @previous_rails_env
    ENV['WOODS_MULTIDATABASE_DIR'] = @previous_database_dir
    FileUtils.rm_rf(@scratch_dir) if @scratch_dir
  end

  def create_tables
    PrimaryRecord.connection.create_table(:accounts) { |t| t.string :name }
    PrimaryRecord.connection.create_table(:posts) do |t|
      t.string :title
      t.integer :status, default: 0
      t.timestamps
    end
    PrimaryRecord.connection.create_table(:comments) do |t|
      t.references :post
      t.text :body
      t.timestamps
    end
    BillingRecord.connection.create_table(:accounts) { |t| t.string :name }
    BillingRecord.connection.create_table(:invoices) { |t| t.references :account, foreign_key: true }
    ReportingRecord.connection.create_table(:subscriptions) do |t|
      t.integer :account_id
      t.integer :subscriber_id
    end
  end

  def model_unit(identifier)
    unit_snapshot(@output_dir).values.find { |unit| unit['type'] == 'model' && unit['identifier'] == identifier }
  end

  def database_identity_supported?
    Gem::Version.new(ActiveRecord::VERSION::STRING) >= Gem::Version.new('6.1')
  end

  def crossings(index = @output_dir)
    read_json(index, 'graph_analysis.json').fetch('cross_database_edges')
  end

  def expected_crossing(from, to, via, from_db, to_db, **extra)
    { 'from' => from, 'to' => to, 'via' => via, 'from_db' => from_db, 'to_db' => to_db,
      'through' => nil, 'through_db' => nil, 'disable_joins' => false,
      'kind' => 'association_across_databases' }.merge(extra.transform_keys(&:to_s))
  end

  it 'uses distinct real databases while concrete models inherit connects_to from abstract parents' do
    models = [MultiAccount, MultiReplicaAccount, MultiSubscription]
    files = models.map do |model|
      model.connection.select_one('PRAGMA database_list').fetch('file')
    end
    expect(files).to contain_exactly(*%w[primary billing reporting].map do |name|
      File.join(@scratch_dir, "#{name}.sqlite3")
    end)
    expect(ActiveRecord::Base.respond_to?(:connection_db_config)).to eq(database_identity_supported?)
    expect(MultiInvoice.connection).to equal(BillingRecord.connection)
    expect(MultiAccount.table_name).to eq(MultiReplicaAccount.table_name)
    expect(MultiInvoice.connection.foreign_keys('invoices').map(&:to_table)).to eq(['accounts'])
    expect(MultiAccount.reflect_on_association(:subscribers).through_reflection.klass).to eq(MultiSubscription)
  end

  it 'publishes inherited database identities and exact cross-database association edges' do
    # Rails 6.0 does not expose connection_db_config. Exercise its real
    # connections above, and require the documented nil/no-report fallback.
    unless database_identity_supported?
      %w[MultiAccount MultiReplicaAccount MultiInvoice MultiSubscription].each do |name|
        expect(model_unit(name).fetch('metadata')['database']).to be_nil
      end
      expect(crossings).to eq([])
      next
    end

    expect(model_unit('MultiAccount').fetch('metadata')).to include('database' => 'primary')
    expect(model_unit('MultiReplicaAccount').fetch('metadata')).to include('database' => 'billing')
    expect(model_unit('MultiInvoice').fetch('metadata')).to include('database' => 'billing')
    expect(model_unit('MultiSubscription').fetch('metadata')).to include('database' => 'reporting')
    expect(crossings).to contain_exactly(
      expected_crossing('MultiAccount', 'MultiInvoice', 'has_many', 'primary', 'billing'),
      expected_crossing('MultiAccount', 'MultiSubscription', 'has_many', 'primary', 'reporting'),
      expected_crossing('MultiAccount', 'MultiReplicaAccount', 'has_many', 'primary', 'billing',
                        through: 'subscriptions', through_db: 'reporting', kind: 'join_through_across_databases'),
      expected_crossing('MultiInvoice', 'MultiAccount', 'belongs_to', 'billing', 'primary'),
      expected_crossing('MultiSubscription', 'MultiAccount', 'belongs_to', 'reporting', 'primary'),
      expected_crossing('MultiSubscription', 'MultiReplicaAccount', 'belongs_to', 'reporting', 'billing')
    )
    # The invoice FK references billing.accounts, not primary.accounts.
    # The same-database owner suppresses a false positive despite the reuse.
    expect(crossings).not_to include(a_hash_including('via' => 'foreign_key'))
  end

  def expect_valid_graph(index)
    require 'woods/resilience/index_validator'
    report = Woods::Resilience::IndexValidator.new(index_dir: index).validate
    expect(report.errors).to be_empty
  end

  it 'keeps the complete incremental index equivalent as an association moves between databases' do
    relative = 'app/models/multi_invoice.rb'
    path = File.join(@app_root, relative)
    original = File.read(path)
    index = File.join(@scratch_dir, 'incremental')
    Woods::Extractor.new(output_dir: index).extract_all
    expect_valid_graph(index)

    [original.sub("class_name: 'MultiAccount'", "class_name: 'MultiReplicaAccount'"),
     original].each_with_index do |source, step|
      File.write(path, source)
      load path
      Woods::Extractor.new(output_dir: index).extract_changed([relative])
      oracle = File.join(@scratch_dir, "oracle-#{step}")
      Woods::Extractor.new(output_dir: oracle).extract_all
      [index, oracle].each { |directory| expect_valid_graph(directory) }
      expect(differences(index, oracle)).to eq([])
      next unless database_identity_supported?

      invoice_crossings = crossings(index).select { |edge| edge['from'] == 'MultiInvoice' }
      expect(invoice_crossings.size).to eq(step.zero? ? 0 : 1)
    end
  ensure
    if original
      File.write(path, original)
      load path
    end
  end
end
