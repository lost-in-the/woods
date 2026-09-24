# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'json'
require 'fileutils'

RSpec.describe 'Assigned Struct and Data class ownership', :booted_app do
  before(:all) do
    @previous_rails_env = ENV.fetch('RAILS_ENV', nil)
    ENV['RAILS_ENV'] = 'test'
    require 'rails'
    require 'active_record/railtie'
    require 'action_controller/railtie'
    require 'action_mailer/railtie'
    require 'active_job/railtie'
    require 'logger'

    @app_root = Dir.mktmpdir('woods_assigned_app')
    FileUtils.cp_r(File.join(File.expand_path('../dummy', __dir__), '.'), @app_root)

    FileUtils.mkdir_p(File.join(@app_root, 'app/models/value_api/container'))
    File.write(File.join(@app_root, 'app/models/value_api/container.rb'), <<~SOURCE)
      module ValueAPI
        class Container
        end
      end
    SOURCE
    { 'criteria' => 'Struct.new', 'page' => defined?(Data) ? 'Data.define' : 'Struct.new' }.each do |name, factory|
      File.write(File.join(@app_root, 'app/models/value_api/container', "#{name}.rb"), <<~SOURCE)
        class ValueAPI::Container
          #{name.capitalize} = #{factory}(:value) do
            def self.call
              raise 'reference extraction must not execute application code'
            end
          end
        end
      SOURCE
    end
    FileUtils.mkdir_p(File.join(@app_root, 'app/models/value_api/module_space'))
    File.write(File.join(@app_root, 'app/models/value_api/module_space.rb'), "module ValueAPI::ModuleSpace; end\n")
    { 'first' => 'Struct.new', 'second' => defined?(Data) ? 'Data.define' : 'Struct.new' }.each do |name, factory|
      File.write(File.join(@app_root, 'app/models/value_api/module_space', "#{name}.rb"), <<~SOURCE)
        module ValueAPI::ModuleSpace
          #{name.capitalize} = #{factory}(:value)
        end
      SOURCE
    end
    FileUtils.mkdir_p(File.join(@app_root, 'lib/assigned_library'))
    { 'first' => 'Struct.new', 'second' => defined?(Data) ? 'Data.define' : 'Struct.new' }.each do |name, factory|
      File.write(File.join(@app_root, 'lib/assigned_library', "#{name}.rb"), <<~SOURCE)
        module AssignedLibrary
          #{name.capitalize} = #{factory}(:value)
        end
      SOURCE
    end
    File.write(File.join(@app_root, 'app/models/value_caller.rb'), <<~SOURCE)
      class ValueCaller
        def call
          ValueAPI::Container::Criteria.call
          AssignedLibrary::First.new(value: 1)
          ValueAPI::ModuleSpace::First.new(value: 1)
        end
      end
    SOURCE
    FileUtils.mkdir_p(File.join(@app_root, 'config/initializers'))
    File.write(File.join(@app_root, 'config/initializers/woods_inflections.rb'), <<~SOURCE)
      Rails.autoloaders.each { |loader| loader.inflector.inflect('value_api' => 'ValueAPI') }
      Dir[Rails.root.join('lib/assigned_library/*.rb')].each { |file| require file }
    SOURCE

    @db_dir = Dir.mktmpdir('woods_assigned_db')
    ENV['WOODS_DUMMY_DB'] = File.join(@db_dir, 'dummy.sqlite3')

    unless defined?(WoodsDummyApplication)
      app_class = Class.new(Rails::Application) do
        config.eager_load = false
        config.logger = Logger.new(IO::NULL)
        config.consider_all_requests_local = false
        config.autoloader = :zeitwerk if config.respond_to?(:autoloader=)
      end
      Object.const_set(:WoodsDummyApplication, app_class)
      WoodsDummyApplication.config.root = @app_root
      WoodsDummyApplication.config.secret_key_base = 'woods-dummy-secret'
    end

    # Rails applications are singletons and every :booted_app spec shares
    # this constant, so a mismatch means another one booted first. Fail
    # loudly rather than quietly testing nothing.
    BootedAppRoot.assert!(@app_root)

    # The initializer above runs before autoload registrations are finalized
    # on Rails 6.0 through 8.1; direct pre-initialize access to
    # Rails.autoloaders.main is nil on Rails 6.0/6.1.
    WoodsDummyApplication.initialize!

    ActiveRecord::Base.establish_connection(:test)
    ActiveRecord::Schema.verbose = false
    ActiveRecord::Schema.define do
      create_table :posts, force: true do |t|
        t.string :title
        t.integer :status, default: 0
        t.timestamps
      end
      create_table :comments, force: true do |t|
        t.references :post
        t.text :body
        t.timestamps
      end
    end
    Rails.application.eager_load!

    require 'woods'
    require 'woods/extractor'
    require 'woods/watch/daemon'
    @original_woods_config = Woods.configuration
    Woods.configuration = Woods::Configuration.new
    Woods.configuration.concurrent_extraction = false
    Woods.configuration.pretty_json = false

    require 'woods/mcp/index_reader'
    @outputs = []
  end

  after(:all) do
    Woods.configuration = @original_woods_config if defined?(@original_woods_config)
    ActiveRecord::Base.remove_connection if defined?(ActiveRecord::Base)
    [@app_root, @db_dir, *@outputs].compact.each { |dir| FileUtils.rm_rf(dir) }
    ENV.delete('WOODS_DUMMY_DB')
    ENV['RAILS_ENV'] = @previous_rails_env
  end

  def full_index
    Dir.mktmpdir('woods_assigned_index').tap do |path|
      @outputs << path
      Woods::Extractor.new(output_dir: path).extract_all
    end
  end

  def graph(index)
    payload = Woods::Generation.new(output_dir: index).payload_dir
    JSON.parse(File.read(File.join(payload, 'dependency_graph.json')))
  end

  it 'publishes child identities and incoming references with the loader inflection' do
    index = full_index
    reader = Woods::MCP::IndexReader.new(index)
    expect(reader.find_unit('ValueAPI::Container::Criteria', type: 'poro')).not_to be_nil
    expect(reader.find_unit('ValueAPI::Container::Page', type: 'poro')).not_to be_nil
    expect(reader.find_unit('ValueAPI::ModuleSpace::First', type: 'poro')).not_to be_nil
    expect(reader.find_unit('ValueAPI::ModuleSpace::Second', type: 'poro')).not_to be_nil
    expect(reader.find_unit('AssignedLibrary::First', type: 'lib')).not_to be_nil
    expect(reader.find_unit('AssignedLibrary::Second', type: 'lib')).not_to be_nil
    expect(graph(index).fetch('reverse').fetch('ValueAPI::Container::Criteria')).to include('ValueCaller')
    expect(graph(index).fetch('reverse').fetch('AssignedLibrary::First')).to include('ValueCaller')
    expect(graph(index).fetch('reverse').fetch('ValueAPI::ModuleSpace::First')).to include('ValueCaller')
  end

  it 'keeps child ownership through an incremental update and refresh with an existing reader' do
    index = full_index
    reader = Woods::MCP::IndexReader.new(index)
    path = File.join(@app_root, 'app/models/value_api/container/criteria.rb')
    original = File.read(path)
    File.write(path, "#{original}\n# an ordinary source edit\n")
    Woods::Extractor.new(output_dir: index).extract_changed([path])
    expect(reader.find_unit('ValueAPI::Container::Criteria', type: 'poro')).not_to be_nil
    Woods::Extractor.new(output_dir: index).refresh(:poros)
    expect(reader.find_unit('ValueAPI::Container::Page', type: 'poro')).not_to be_nil
    expect(graph(index)).to eq(graph(full_index))
  ensure
    File.write(path, original) if original
  end

  it 'replaces an ordinary class with an assigned child and removes it without damaging the wrapper' do
    path = File.join(@app_root, 'app/models/value_api/container/criteria.rb')
    original = File.read(path)
    ValueAPI::Container.send(:remove_const, :Criteria)
    File.write(path, "class ValueAPI::Container\n  class Criteria\n  end\nend\n")
    load path
    index = full_index
    reader = Woods::MCP::IndexReader.new(index)
    ValueAPI::Container.send(:remove_const, :Criteria)
    File.write(path, original)
    load path
    Woods::Extractor.new(output_dir: index).extract_changed([path])
    expect(reader.find_unit('ValueAPI::Container::Criteria', type: 'poro')).not_to be_nil
    expect(graph(index)).to eq(graph(full_index))
    ValueAPI::Container.send(:remove_const, :Criteria)
    File.unlink(path)
    Woods::Extractor.new(output_dir: index).extract_changed([path])
    expect(reader.find_unit('ValueAPI::Container::Criteria', type: 'poro')).to be_nil
    expect(reader.find_unit('ValueAPI::Container', type: 'poro')).not_to be_nil
    expect(graph(index).fetch('reverse').fetch('ValueAPI::Container::Criteria', [])).to be_empty
    expect(graph(index)).to eq(graph(full_index))
  ensure
    if original
      ValueAPI::Container.send(:remove_const, :Criteria) if ValueAPI::Container.const_defined?(:Criteria, false)
      File.write(path, original)
      load path
    end
  end
  it 'retains assigned library identities through a source update and library refresh' do
    index = full_index
    reader = Woods::MCP::IndexReader.new(index)
    path = File.join(@app_root, 'lib/assigned_library/first.rb')
    original = File.read(path)
    replacement = defined?(Data) ? original.sub('Struct.new', 'Data.define') : "#{original}\n# library edit\n"
    AssignedLibrary.send(:remove_const, :First)
    File.write(path, replacement)
    load path
    Woods::Extractor.new(output_dir: index).extract_changed([path])
    expect(reader.find_unit('AssignedLibrary::First', type: 'lib')).not_to be_nil
    Woods::Extractor.new(output_dir: index).refresh(:libs)
    expect(graph(index)).to eq(graph(full_index))
  ensure
    if original
      AssignedLibrary.send(:remove_const, :First)
      File.write(path, original)
      load path
    end
  end

  [1, 2].each do |old_version|
    it "refuses analysis cache v#{old_version} atomically and repairs it with a complete full extraction" do
      index = full_index
      generation = Woods::Generation.new(output_dir: index)
      marker = File.binread(File.join(index, 'generation.json'))
      path = File.join(generation.payload_dir, Woods::SourceReferences::Cache::FILE_NAME)
      cache = JSON.parse(File.read(path)).merge('version' => old_version)
      File.write(path, JSON.generate(cache))
      changed = File.join(@app_root, 'app/models/value_caller.rb')
      expect { Woods::Extractor.new(output_dir: index).extract_changed([changed]) }
        .to raise_error(Woods::ExtractionError, /full extraction/i)
      expect(File.binread(File.join(index, 'generation.json'))).to eq(marker)
      Woods::Extractor.new(output_dir: index).extract_all
      path = File.join(generation.payload_dir, Woods::SourceReferences::Cache::FILE_NAME)
      expect(JSON.parse(File.read(path))['version']).to eq(3)
      expect(graph(index).fetch('reverse').fetch('ValueAPI::Container::Criteria')).to include('ValueCaller')
    end
  end

  it 'reloads a changed value constructor through the real watcher with a held reader' do
    index = full_index
    reader = Woods::MCP::IndexReader.new(index)
    path = File.join(@app_root, 'app/models/value_api/container/criteria.rb')
    original = File.read(path)
    prior = ValueAPI::Container::Criteria
    replacement = if defined?(Data)
                    original.sub('Struct.new', 'Data.define')
                  else
                    "class ValueAPI::Container\n  class Criteria\n  end\nend\n"
                  end
    File.write(path, replacement)
    daemon = Woods::Watch::Daemon.new(output_dir: index, root: @app_root, debounce: 0)
    expect(Woods::Watch::Daemon::RailsReloader.new.enabled?).to be(true)
    before = Woods::Generation.new(output_dir: index).current.number
    result = daemon.process([path])
    expect(result[:action]).to eq(:incremental)
    expect(Woods::Generation.new(output_dir: index).current.number).to eq(before + 1)
    expect(ValueAPI::Container::Criteria).not_to equal(prior)
    expect(reader.find_unit('ValueAPI::Container::Criteria', type: 'poro')).not_to be_nil
    expect(graph(index).fetch('reverse').fetch('ValueAPI::Container::Criteria')).to include('ValueCaller')
    expect(graph(index)).to eq(graph(full_index))
  ensure
    if original
      File.write(path, original)
      Rails.application.reloader.reload!
      Rails.application.eager_load!
    end
  end
end
