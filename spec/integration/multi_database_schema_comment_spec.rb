# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'

# Separate process: boot a disposable copy of the dummy app with the
# multi-database overlay, then give the primary and billing databases tables
# of the same names that differ in their indexes and foreign keys. A model's
# schema header must describe the table in the model's own database.
RSpec.describe 'Booted model schema comments across databases', :booted_app do
  let(:unknown_indexes) { '# Indexes: unknown (could not be read)' }
  let(:unknown_foreign_keys) { '# Foreign Keys: unknown (could not be read)' }

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

    @scratch_dir = Dir.mktmpdir('woods_schema_comment')
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
    Rails.application.eager_load!
    @archive_database = File.join(@scratch_dir, 'archive.sqlite3')
    define_models
    @databases_connected = true
    create_tables

    require 'woods'
    require 'woods/extractors/model_extractor'
  end

  after(:all) do
    if @databases_connected
      [Archive::Record, BillingRecord, ActiveRecord::Base].each do |klass|
        klass.remove_connection
      rescue StandardError
        nil
      end
    end
    ENV['RAILS_ENV'] = @previous_rails_env
    ENV['WOODS_MULTIDATABASE_DIR'] = @previous_database_dir
    FileUtils.rm_rf(@scratch_dir) if @scratch_dir
  end

  # Billing::* reach the billing database through BillingRecord's
  # connects_to; Archive::Record connects on its own.
  def define_models
    define_model(Object.const_set(:Ledger, Module.new), :Invoice, ActiveRecord::Base, table: 'invoices')
    { Invoice: 'invoices', Note: 'notes', Refund: 'refunds' }.each do |name, table|
      define_model(Billing, name, BillingRecord, table: table)
    end
    archived = define_model(Billing, :ArchivedRecord, BillingRecord, abstract: true)
    define_model(Billing, :ArchivedInvoice, archived, table: 'invoices')

    archive = Object.const_set(:Archive, Module.new)
    define_model(archive, :Record, ActiveRecord::Base, abstract: true)
      .establish_connection(adapter: 'sqlite3', database: @archive_database)
    define_model(archive, :Invoice, Archive::Record, table: 'invoices')
  end

  def define_model(namespace, name, parent, table: nil, abstract: false)
    model = namespace.const_set(name, Class.new(parent))
    model.abstract_class = true if abstract
    model.table_name = table if table
    model
  end

  # The same table names on both sides, with different indexes and foreign
  # key targets; refunds exists on the primary database only.
  def create_tables
    create_primary_tables(ActiveRecord::Base.connection)
    create_billing_tables(BillingRecord.connection)
    archive = Archive::Record.connection
    archive.create_table(:archived_batches) { |t| t.string :label }
    archive.create_table(:invoices) { |t| t.references :archived_batch, foreign_key: true }
  end

  def create_primary_tables(primary)
    primary.create_table(:customers) { |t| t.string :name }
    primary.create_table(:invoices) do |t|
      t.string :number
      t.references :customer, foreign_key: true
      t.index :number, unique: true
    end
    primary.create_table(:notes) do |t|
      t.text :body
      t.references :invoice, foreign_key: true
    end
    primary.create_table(:refunds) { |t| t.integer :cents }
  end

  def create_billing_tables(billing)
    billing.create_table(:accounts) { |t| t.string :name }
    billing.create_table(:invoices) do |t|
      t.references :account, foreign_key: true
      t.date :due_on, index: true
    end
    billing.create_table(:notes) { |t| t.text :body }
  end

  # The schema header: the unit's leading comment block, empty when the unit
  # has none. These models are defined here, so the source after it is this
  # file.
  def header(model)
    unit = Woods::Extractors::ModelExtractor.new.extract_model(model)
    expect(unit).not_to be_nil
    lines = unit.source_code.lines.map(&:chomp)
    return [] unless lines.first == '# == Schema Information'

    lines.take_while { |line| line.start_with?('#') }
  end

  # The entries under one header section, nil when the section is absent.
  def section(lines, title)
    start = lines.index("# #{title}:")
    start && lines.drop(start + 1).take_while { |line| line.start_with?('#   ') }
  end

  it 'describes a second-database model with its own indexes and foreign keys' do
    lines = header(Billing::Invoice)

    expect(section(lines, 'Indexes')).to contain_exactly('#   index_invoices_on_account_id: [account_id]',
                                                         '#   index_invoices_on_due_on: [due_on]')
    expect(section(lines, 'Foreign Keys')).to eq(['#   invoices.account_id → accounts'])
  end

  it 'resolves the database of a model below an intermediate abstract class' do
    lines = header(Billing::ArchivedInvoice)

    expect(section(lines, 'Indexes')).to contain_exactly('#   index_invoices_on_account_id: [account_id]',
                                                         '#   index_invoices_on_due_on: [due_on]')
    expect(section(lines, 'Foreign Keys')).to eq(['#   invoices.account_id → accounts'])
  end

  it 'keeps the default-database description for a model on the default database' do
    lines = header(Ledger::Invoice)

    expect(section(lines, 'Indexes')).to contain_exactly('#   index_invoices_on_customer_id: [customer_id]',
                                                         '#   index_invoices_on_number: [number] (unique)')
    expect(section(lines, 'Foreign Keys')).to eq(['#   invoices.customer_id → customers'])
    expect(lines).not_to include(unknown_indexes, unknown_foreign_keys)
  end

  it 'prints no index or foreign key section for a table that has none in its own database' do
    lines = header(Billing::Note)

    expect(lines).to include('# Table: notes', '# Columns:')
    expect(section(lines, 'Indexes')).to be_nil
    expect(section(lines, 'Foreign Keys')).to be_nil
    expect(lines).not_to include(unknown_indexes, unknown_foreign_keys)
  end

  it 'writes no schema header for a table that exists only in another database' do
    expect(header(Billing::Refund)).to eq([])
  end

  it 'reports indexes and foreign keys as unknown when the model database cannot be read' do
    expect(section(header(Archive::Invoice), 'Indexes'))
      .to eq(['#   index_invoices_on_archived_batch_id: [archived_batch_id]'])
    break_archive_database

    lines = header(Archive::Invoice)

    expect(lines).to include('# Table: invoices', '# Columns:', unknown_indexes, unknown_foreign_keys)
    expect(section(lines, 'Indexes')).to be_nil
    expect(section(lines, 'Foreign Keys')).to be_nil
  end

  # The model's schema stays cached, as in a running process whose database
  # goes away: the held connection is closed, and the file is replaced by a
  # directory so a reconnect cannot open it either.
  def break_archive_database
    connection = if Archive::Record.respond_to?(:lease_connection)
                   Archive::Record.lease_connection
                 else
                   Archive::Record.connection
                 end
    connection.disconnect!
    File.rename(@archive_database, "#{@archive_database}.moved")
    Dir.mkdir(@archive_database)
  end
end
