# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'json'
require 'fileutils'

# Finding 2 (PR-251 round 2): the governed lookup must follow the ACTIVE
# Zeitwerk inflector. With `api => API` configured, the loader expects
# API::Container::Parser from app/services/api/container/parser.rb; a local
# camelizer derives Api::Container::Parser, both wrapper siblings then fall
# back to the source parser, derive API::Container, and the fail-closed
# collision guard aborts publication. This spec boots a copy of the dummy
# with the inflection and two wrapper siblings, and asserts the exact child
# identifiers across a full and an incremental extraction.
#
# Tagged :booted_app — excluded from the default `rake spec`, opted into by
# the CI Rails-version matrix (its own step; Rails applications are
# singletons and cannot share a process with the other booted specs).
RSpec.describe 'Inflected Zeitwerk naming', :booted_app do
  before(:all) do
    require 'rails'
    require 'active_record/railtie'
    require 'action_controller/railtie'
    require 'action_mailer/railtie'
    require 'active_job/railtie'
    require 'logger'

    @app_root = Dir.mktmpdir('woods_inflected_app')
    FileUtils.cp_r(File.join(File.expand_path('../dummy', __dir__), '.'), @app_root)

    # The wrapper siblings whose naming depends on the custom inflection.
    # `container` needs an explicit namespace file: an implicit namespace
    # would be pre-created as a Module and `class Container` would be a
    # boot-time TypeError (same rule as the dummy's Domain::Container).
    FileUtils.mkdir_p(File.join(@app_root, 'app/services/api/container'))
    File.write(File.join(@app_root, 'app/services/api/container.rb'), <<~RUBY)
      module API
        class Container
          def self.wrap(input)
            input
          end
        end
      end
    RUBY
    %w[parser renderer].each do |name|
      File.write(File.join(@app_root, 'app/services/api/container', "#{name}.rb"), <<~RUBY)
        module API
          class Container
            class #{name.capitalize}
              def call(input)
                input
              end
            end
          end
        end
      RUBY
    end
    FileUtils.mkdir_p(File.join(@app_root, 'config/initializers'))
    File.write(File.join(@app_root, 'config/initializers/woods_inflections.rb'), <<~RUBY)
      Rails.autoloaders.each do |loader|
        loader.inflector.inflect('api' => 'API')
      end
    RUBY

    @db_dir = Dir.mktmpdir('woods_inflected_db')
    ENV['WOODS_DUMMY_DB'] = File.join(@db_dir, 'dummy.sqlite3')

    unless defined?(WoodsDummyApplication)
      app_class = Class.new(Rails::Application) do
        config.eager_load = false
        config.logger = Logger.new(IO::NULL)
        config.consider_all_requests_local = true
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

    @output_dir = Dir.mktmpdir('woods_inflected_out')
    Woods::Extractor.new(output_dir: @output_dir).extract_all
  end

  after(:all) do
    Woods.configuration = @original_woods_config if defined?(@original_woods_config)
    ActiveRecord::Base.remove_connection if defined?(ActiveRecord::Base)
    [@app_root, @db_dir, @output_dir].compact.each { |dir| FileUtils.rm_rf(dir) }
    ENV.delete('WOODS_DUMMY_DB')
  end

  def identifiers_in(type)
    payload_dir = Woods::Generation.new(output_dir: @output_dir).payload_dir
    path = File.join(payload_dir, type, '_index.json')
    return [] unless File.exist?(path)

    JSON.parse(File.read(path)).map { |entry| entry['identifier'] }
  end

  def daemon_for(root)
    Woods::Watch::Daemon.new(
      output_dir: @output_dir,
      root: root,
      reloader: instance_double(Woods::Watch::Daemon::RailsReloader, enabled?: true, reload!: true),
      debounce: 0
    )
  end

  it 'publishes the exact inflected child identifiers from a full extraction' do
    services = identifiers_in('services')
    expect(services).to include('API::Container::Parser', 'API::Container::Renderer')

    # The un-inflected wrapper fixtures in the same tree are unaffected.
    expect(services).to include('Domain::Container::Parser', 'Domain::Container::Renderer')
  end

  it 'keeps the inflected identifiers through an incremental cycle' do
    changed = 'app/services/api/container/parser.rb'
    File.write(File.join(@app_root, changed), <<~RUBY)
      module API
        class Container
          class Parser
            # touched so the daemon has something to re-derive
            def call(input)
              input
            end
          end
        end
      end
    RUBY

    daemon_for(@app_root).process([changed])

    generation = Woods::Generation.new(output_dir: @output_dir).current.number
    expect(generation).to eq(2)
    expect(identifiers_in('services')).to include('API::Container::Parser', 'API::Container::Renderer')
  end
end
