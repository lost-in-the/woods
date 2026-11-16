# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'json'
require 'fileutils'
require 'securerandom'

# One booted dummy app, its database switched between the states a fresh
# checkout can be in. Each example runs a real full extraction and reads what
# the published index says about the schema it could read.
RSpec.describe 'Booted extraction over an unreadable database schema', :booted_app do
  before(:all) do
    require 'rails'
    require 'active_record/railtie'
    require 'action_controller/railtie'
    require 'action_mailer/railtie'
    require 'active_job/railtie'
    require 'logger'
    require File.expand_path('../dummy/config/application_config', __dir__)

    @scratch = Dir.mktmpdir('woods_schema_readability')
    @app_root = File.join(@scratch, 'app')
    FileUtils.cp_r(File.expand_path('../dummy', __dir__), @app_root)
    ENV['WOODS_DUMMY_DB'] = File.join(@scratch, 'boot.sqlite3')

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
    Rails.application.eager_load!

    # The second database of the multi-database example, defined for the whole
    # file: a model class stays in ActiveRecord::Base.descendants after its
    # constant is removed, and every later extraction would fail on it. It
    # shares the primary connection except inside that example.
    Object.const_set(:SchemaProbeRecord, Class.new(ActiveRecord::Base) { self.abstract_class = true })
    Object.const_set(:SchemaProbeLedger, Class.new(SchemaProbeRecord) { self.table_name = 'ledgers' })

    require 'woods'
    require 'woods/extractor'
    require 'woods/resilience/index_validator'
    @original_woods_config = Woods.configuration
    Woods.configuration = Woods::Configuration.new
    Woods.configuration.concurrent_extraction = false
  end

  after(:all) do
    Woods.configuration = @original_woods_config if defined?(@original_woods_config)
    ActiveRecord::Base.remove_connection if defined?(ActiveRecord::Base)
    FileUtils.rm_rf(@scratch) if @scratch
    ENV.delete('WOODS_DUMMY_DB')
  end

  # A path SQLite cannot open, so Rails raises the missing-database error a
  # server adapter raises for a database that was never created.
  let(:missing_database) { '/dev/null/woods-missing.sqlite3' }

  def connect(database, tables: [])
    forget_columns
    ActiveRecord::Base.establish_connection(adapter: 'sqlite3', database: database)
    tables.each { |table| ActiveRecord::Base.connection.create_table(table, force: true) { |t| t.string :title } }
    forget_columns
  end

  # Before Rails 6.1, resetting column information opens a connection, which
  # an unopenable database refuses; that model then keeps no cache to clear.
  def forget_columns
    ActiveRecord::Base.descendants.each do |model|
      model.reset_column_information
    rescue StandardError
      nil
    end
  end

  def fresh_database(name)
    File.join(@scratch, "#{name}-#{SecureRandom.hex(4)}.sqlite3")
  end

  def extract(output_dir = Dir.mktmpdir('index', @scratch))
    Woods::Extractor.new(output_dir: output_dir).extract_all
    output_dir
  end

  def payload(output_dir)
    Woods::Generation.new(output_dir: output_dir).payload_dir
  end

  def manifest(output_dir)
    JSON.parse(File.read(payload(output_dir).join('manifest.json')))
  end

  def schema_states(output_dir)
    manifest(output_dir).fetch('schema_readability').then do |summary|
      [summary['state'], summary['databases'].map { |database| database['state'] }]
    end
  end

  def model_unit(output_dir, identifier)
    Dir[payload(output_dir).join('models', '*.json').to_s].reject { |path| path.end_with?('_index.json') }
                                                          .map { |path| JSON.parse(File.read(path)) }
                                                          .find { |unit| unit['identifier'] == identifier }
  end

  def file_bytes(directory)
    paths = Dir[File.join(directory, '**', '*')].select { |path| File.file?(path) }
    paths.sort.to_h { |path| [path, File.binread(path)] }
  end

  def validation(output_dir)
    Woods::Resilience::IndexValidator.new(index_dir: output_dir).validate
  end

  it 'records a database that does not exist as unreachable, and validation warns' do
    connect(missing_database)

    index = extract

    expect(schema_states(index)).to eq(['unreadable', ['unreachable']])
    expect(validation(index).warnings).to include(a_string_including('could not connect', 'db:prepare'))
    expect(validation(index).incremental).not_to be_ready
  end

  it 'records a database that refuses the connection as unreachable' do
    connect(fresh_database('refused'))
    allow(ActiveRecord::Base.connection_pool).to receive(:with_connection)
      .and_raise(ActiveRecord::ConnectionNotEstablished, 'connection refused')

    expect(schema_states(extract)).to eq(['unreadable', ['unreachable']])
  end

  it 'records a database that exists but was never migrated as empty, beside models with no columns' do
    connect(fresh_database('unmigrated'))

    index = extract

    expect(schema_states(index)).to eq(['unreadable', ['empty']])
    expect(model_unit(index, 'Post').dig('metadata', 'table_exists')).to be(false)
    expect(validation(index).warnings).to include(a_string_including('holds no tables'))
  end

  it 'warns once in the log, naming the cause and both fixes' do
    connect(fresh_database('logged'))
    allow(Rails.logger).to receive(:warn).and_call_original

    extract

    expect(Rails.logger).to have_received(:warn)
      .with(a_string_including('could not be read', 'holds no tables', 'db:prepare', 'woods:seed')).once
  end

  it 'records a migrated database as readable, without a warning' do
    connect(fresh_database('ready'), tables: %i[posts comments])

    index = extract

    expect(schema_states(index)).to eq(['readable', ['readable']])
    expect(model_unit(index, 'Post').dig('metadata', 'column_count')).to be > 1
    expect(validation(index).warnings.grep(/database schema/)).to be_empty
    expect(validation(index).incremental).to be_ready
  end

  it 'keeps the schema readable when one model table is absent beside another that exists' do
    connect(fresh_database('partial'), tables: %i[posts])

    index = extract

    expect(schema_states(index)).to eq(['readable', ['readable']])
    expect(model_unit(index, 'Comment').dig('metadata', 'table_exists')).to be(false)
  end

  it "asks no database on behalf of the framework's own models, so an app without models is not warned" do
    connect(fresh_database('framework-only'))
    # Before Rails 7.1 the migration bookkeeping classes are Active Record models.
    bookkeeping_models = ActiveRecord::SchemaMigration < ActiveRecord::Base
    framework = ActiveRecord::Base.descendants.select do |klass|
      Woods::Extractors::SourceOrigin.constant_origin(klass) == Woods::Extractors::SourceOrigin::FRAMEWORK
    end
    expect(framework).to include(ActiveRecord::SchemaMigration) if bookkeeping_models

    expect(Woods::Extractors::TableCatalog.schema_readability(connection_classes: [ActiveRecord::Base, *framework]))
      .to eq([])
  end

  it 'reports one unreachable database of two while reading the other' do
    connect(fresh_database('primary'), tables: %i[posts comments])
    settings = { adapter: 'sqlite3', database: missing_database }
    # Rails 6.0 pools name no configuration, so only 6.1+ can name the ledger database.
    named = ActiveRecord::ConnectionAdapters::ConnectionPool.method_defined?(:db_config)
    SchemaProbeRecord.establish_connection(
      named ? ActiveRecord::DatabaseConfigurations::HashConfig.new('test', 'ledger', settings) : settings
    )

    states = manifest(extract).fetch('schema_readability')

    expect(states['state']).to eq('unreadable')
    expect(states['databases'].map { |database| database['state'] }).to contain_exactly('unreachable', 'readable')
    if named
      expect(states['databases']).to contain_exactly(a_hash_including('name' => 'ledger', 'state' => 'unreachable'),
                                                     a_hash_including('name' => 'primary', 'state' => 'readable'))
    end
  ensure
    SchemaProbeRecord.remove_connection
  end

  describe 'incremental runs' do
    let(:controller) { Dir[File.join(@app_root, 'app/controllers/**/*.rb')].min }

    def touch(path)
      File.write(path, "#{File.read(path)}\n# edited\n")
      path
    end

    it 'refuses to build on an unreadable baseline, and the next full run repairs it' do
      connect(fresh_database('later'))
      index = extract
      ActiveRecord::Base.connection.create_table(:posts, force: true) { |t| t.string :title }
      ActiveRecord::Base.connection.create_table(:comments, force: true) { |t| t.references :post }
      forget_columns
      published = Woods::Generation.new(output_dir: index).current.number

      expect { Woods::Extractor.new(output_dir: index).extract_changed([controller]) }
        .to raise_error(Woods::ExtractionError, /without a readable database schema.*full woods:extract/)
      expect(Woods::Generation.new(output_dir: index).current.number).to eq(published)

      extract(index)

      expect(schema_states(index)).to eq(['readable', ['readable']])
      expect(model_unit(index, 'Post').dig('metadata', 'table_exists')).to be(true)
      expect(validation(index).incremental).to be_ready
    end

    it 'carries a readable baseline record into the incremental manifest' do
      connect(fresh_database('carried'), tables: %i[posts comments])
      index = extract
      recorded = manifest(index).fetch('schema_readability')
      published = Woods::Generation.new(output_dir: index).current.number

      Woods::Extractor.new(output_dir: index).extract_changed([touch(controller)])

      expect(Woods::Generation.new(output_dir: index).current.number).to be > published
      expect(manifest(index).fetch('schema_readability')).to eq(recorded)
    end

    it 'refuses an incremental run that re-extracts a model after the database went away' do
      connect(fresh_database('vanishing'), tables: %i[posts comments])
      index = extract
      connect(missing_database)

      post = touch(File.join(@app_root, 'app/models/post.rb'))

      expect { Woods::Extractor.new(output_dir: index).extract_changed([post]) }
        .to raise_error(Woods::ExtractionError, /cannot be read now \(primary: could not connect\)/)
    end

    it 'refuses an incremental run that re-extracts a model while the database holds no tables' do
      connect(fresh_database('emptied'), tables: %i[posts comments])
      index = extract
      connect(fresh_database('emptied-now'))
      published = Woods::Generation.new(output_dir: index).current.number

      post = touch(File.join(@app_root, 'app/models/post.rb'))

      expect { Woods::Extractor.new(output_dir: index).extract_changed([post]) }
        .to raise_error(Woods::ExtractionError, /cannot be read now \(primary: holds no tables\)/)
      expect(Woods::Generation.new(output_dir: index).current.number).to eq(published)
      expect(model_unit(index, 'Post').dig('metadata', 'table_exists')).to be(true)
    end

    it 'refuses a refresh of the models while the database holds no tables' do
      connect(fresh_database('refreshed'), tables: %i[posts comments])
      index = extract
      connect(fresh_database('refreshed-now'))
      allow(Woods::Extractors::ModelExtractor).to receive(:new).and_call_original
      marker = File.binread(File.join(index, Woods::Generation::FILENAME))
      published = payload(index)
      payload_files = file_bytes(published)

      expect { Woods::Extractor.new(output_dir: index).refresh(:models) }
        .to raise_error(Woods::ExtractionError,
                        %r{cannot be read now \(primary: holds no tables\).*bin/rails db:prepare})
      expect(Woods::Extractors::ModelExtractor).not_to have_received(:new)
      expect(File.binread(File.join(index, Woods::Generation::FILENAME))).to eq(marker)
      expect(payload(index)).to eq(published)
      expect(file_bytes(published)).to eq(payload_files)
    end

    it 'refuses a refresh over an unreadable baseline' do
      connect(fresh_database('unreadable-refresh'))
      index = extract

      expect { Woods::Extractor.new(output_dir: index).refresh(:models) }
        .to raise_error(Woods::ExtractionError, /without a readable database schema.*full woods:extract/)
    end

    it 'keeps updating units that do not read the schema while the database holds no tables' do
      connect(fresh_database('controller-only'), tables: %i[posts comments])
      index = extract
      connect(fresh_database('controller-only-now'))
      published = Woods::Generation.new(output_dir: index).current.number

      Woods::Extractor.new(output_dir: index).extract_changed([touch(controller)])

      expect(Woods::Generation.new(output_dir: index).current.number).to be > published
      expect(model_unit(index, 'Post').dig('metadata', 'table_exists')).to be(true)
    end
  end
end
