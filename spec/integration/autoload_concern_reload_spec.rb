# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'json'
require 'fileutils'

# #1040: concerns kept under an autoload-only root (app/views) are loaded by
# nothing but the component walk. After a Rails reload, an incremental run
# that read the shared concern classification before that walk pruned them,
# and every later reload/incremental cycle kept them missing.
RSpec.describe 'Autoload-only concerns across Rails reloads', :booted_app do
  before(:all) do
    @previous_rails_env = ENV.fetch('RAILS_ENV', nil)
    ENV['RAILS_ENV'] = 'test'
    require 'rails'
    require 'active_record/railtie'
    require 'action_controller/railtie'
    require 'action_mailer/railtie'
    require 'active_job/railtie'
    require 'logger'

    @app_root = Dir.mktmpdir('woods_autoload_concern_app')
    FileUtils.cp_r(File.join(File.expand_path('../dummy', __dir__), '.'), @app_root)
    require File.join(@app_root, 'config/application_config')

    File.write(File.join(@app_root, 'app/views/ui/decorated.rb'), <<~SOURCE)
      module Ui
        module Decorated
          extend ActiveSupport::Concern
        end
      end
    SOURCE
    File.write(File.join(@app_root, 'app/views/ui/labelled.rb'), <<~SOURCE)
      module Ui
        module Labelled
          extend ActiveSupport::Concern
          include Ui::Decorated
        end
      end
    SOURCE
    FileUtils.mkdir_p(File.join(@app_root, 'app/helpers'))
    File.write(File.join(@app_root, 'app/helpers/labels_helper.rb'), <<~SOURCE)
      module LabelsHelper
        def label_for(value)
          value.to_s
        end
      end
    SOURCE

    @db_dir = Dir.mktmpdir('woods_autoload_concern_db')
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
      WoodsDummyConfig.apply(WoodsDummyApplication.config, @app_root)
    end

    BootedAppRoot.assert!(@app_root)
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
    require 'woods/mcp/index_reader'
    @original_woods_config = Woods.configuration
    Woods.configuration = Woods::Configuration.new
    Woods.configuration.concurrent_extraction = false
    Woods.configuration.pretty_json = false
    @outputs = []
  end

  after(:all) do
    Woods.configuration = @original_woods_config if defined?(@original_woods_config)
    ActiveRecord::Base.remove_connection if defined?(ActiveRecord::Base)
    [@app_root, @db_dir, *@outputs].compact.each { |dir| FileUtils.rm_rf(dir) }
    ENV.delete('WOODS_DUMMY_DB')
    ENV['RAILS_ENV'] = @previous_rails_env
  end

  def new_index_dir
    Dir.mktmpdir('woods_autoload_concern_index').tap { |path| @outputs << path }
  end

  def full_index
    new_index_dir.tap { |path| Woods::Extractor.new(output_dir: path).extract_all }
  end

  def graph(index)
    payload = Woods::Generation.new(output_dir: index).payload_dir
    JSON.parse(File.read(File.join(payload, 'dependency_graph.json')))
  end

  # Edit an unrelated file and reload Rails as the watch daemon would, which
  # unloads everything under app/views and loads nothing back.
  def edit_and_reload(path, note)
    File.write(path, "#{File.read(path)}\n# #{note}\n")
    Rails.application.reloader.reload!
    Rails.application.eager_load!
  end

  def expect_concerns(reader, index)
    expect(reader.find_unit('Ui::Decorated', type: 'concern')).not_to be_nil
    expect(reader.find_unit('Ui::Labelled', type: 'concern')).not_to be_nil
    expect(graph(index).fetch('nodes').keys).to include('Ui::Decorated', 'Ui::Labelled')
  end

  it 'classifies both concerns in a full extraction' do
    index = full_index
    reader = Woods::MCP::IndexReader.new(index)
    expect_concerns(reader, index)
    expect(graph(index).fetch('reverse').fetch('Ui::Decorated', [])).to include('Ui::Labelled')
  end

  %w[app/helpers/labels_helper.rb app/controllers/posts_controller.rb].each do |relative|
    it "keeps them through repeated reload/incremental cycles after editing #{relative}" do
      path = File.join(@app_root, relative)
      original = File.read(path)
      index = full_index
      reader = Woods::MCP::IndexReader.new(index)
      reused = Woods::Extractor.new(output_dir: index)

      3.times do |cycle|
        edit_and_reload(path, "unrelated edit #{cycle}")
        writer = cycle.even? ? Woods::Extractor.new(output_dir: index) : reused
        writer.extract_changed([path])
        expect_concerns(reader, index)
      end

      expect(graph(index).fetch('reverse').fetch('Ui::Decorated', [])).to include('Ui::Labelled')
      expect(graph(index)).to eq(graph(full_index))
    ensure
      if original
        File.write(path, original)
        Rails.application.reloader.reload!
        Rails.application.eager_load!
      end
    end
  end

  it 'classifies both concerns in a concurrent full extraction after a reload' do
    Woods.configuration.concurrent_extraction = true
    Rails.application.reloader.reload!
    Rails.application.eager_load!
    index = full_index
    expect_concerns(Woods::MCP::IndexReader.new(index), index)
  ensure
    Woods.configuration.concurrent_extraction = false
  end

  it 'keeps them through a reload followed by a named refresh' do
    index = full_index
    reader = Woods::MCP::IndexReader.new(index)
    Rails.application.reloader.reload!
    Rails.application.eager_load!
    Woods::Extractor.new(output_dir: index).refresh(:concerns)
    expect_concerns(reader, index)
    expect(graph(index)).to eq(graph(full_index))
  end

  it 'keeps them through the watch daemon reload and incremental run' do
    path = File.join(@app_root, 'app/helpers/labels_helper.rb')
    original = File.read(path)
    index = full_index
    reader = Woods::MCP::IndexReader.new(index)
    File.write(path, "#{original}\n# daemon edit\n")
    daemon = Woods::Watch::Daemon.new(output_dir: index, root: @app_root, debounce: 0)
    result = daemon.process([path])
    expect(result[:action]).to eq(:incremental)
    expect_concerns(reader, index)
    expect(graph(index)).to eq(graph(full_index))
  ensure
    if original
      File.write(path, original)
      Rails.application.reloader.reload!
      Rails.application.eager_load!
    end
  end

  it 'leaves them unclassified when component_paths opts out of the walk' do
    Woods.configuration.component_paths = []
    Rails.application.reloader.reload!
    Rails.application.eager_load!
    index = full_index
    reader = Woods::MCP::IndexReader.new(index)
    expect(reader.find_unit('Ui::Labelled', type: 'concern')).to be_nil
  ensure
    Woods.configuration.component_paths = nil
  end
end
