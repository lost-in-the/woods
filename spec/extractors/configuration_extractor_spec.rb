# frozen_string_literal: true

require 'spec_helper'
require 'set'
require 'tmpdir'
require 'fileutils'
require 'active_support/core_ext/object/blank'
require 'woods/extractors/configuration_extractor'

RSpec.describe Woods::Extractors::ConfigurationExtractor do
  include_context 'extractor setup'

  # Stub Rails.application for BehavioralProfile integration
  before do
    rails_config = double('RailsConfig')
    allow(rails_config).to receive(:respond_to?).and_return(false)
    rails_app = double('RailsApp', config: rails_config)
    allow(Rails).to receive(:application).and_return(rails_app)
    allow(Rails).to receive(:version).and_return('7.1.3')
  end

  # ── Initialization ───────────────────────────────────────────────────

  describe '#initialize' do
    it 'handles missing config directories gracefully' do
      extractor = described_class.new
      units = extractor.extract_all
      config_units = units.reject { |u| u.identifier == 'BehavioralProfile' }
      expect(config_units).to eq([])
    end
  end

  # ── extract_all ──────────────────────────────────────────────────────

  describe '#extract_all' do
    it 'discovers initializer files' do
      create_file('config/initializers/devise.rb', <<~RUBY)
        Devise.setup do |config|
          config.mailer_sender = 'noreply@example.com'
        end
      RUBY

      units = described_class.new.extract_all
      config_units = units.reject { |u| u.identifier == 'BehavioralProfile' }
      expect(config_units.size).to eq(1)
      expect(config_units.first.identifier).to eq('initializers/devise.rb')
      expect(config_units.first.type).to eq(:configuration)
    end

    it 'discovers environment files' do
      create_file('config/environments/production.rb', <<~RUBY)
        Rails.application.configure do
          config.cache_classes = true
          config.eager_load = true
        end
      RUBY

      units = described_class.new.extract_all
      config_units = units.reject { |u| u.identifier == 'BehavioralProfile' }
      expect(config_units.size).to eq(1)
      expect(config_units.first.identifier).to eq('environments/production.rb')
    end

    it 'discovers files from both directories' do
      create_file('config/initializers/cors.rb', <<~RUBY)
        Rails.application.config.middleware.insert_before 0, Rack::Cors do
        end
      RUBY

      create_file('config/environments/development.rb', <<~RUBY)
        Rails.application.configure do
          config.cache_classes = false
        end
      RUBY

      units = described_class.new.extract_all
      config_units = units.reject { |u| u.identifier == 'BehavioralProfile' }
      expect(config_units.size).to eq(2)
    end

    it 'includes BehavioralProfile unit' do
      units = described_class.new.extract_all
      profile = units.find { |u| u.identifier == 'BehavioralProfile' }
      expect(profile).not_to be_nil
      expect(profile.type).to eq(:configuration)
      expect(profile.metadata[:config_type]).to eq('behavioral_profile')
    end
  end

  # ── extract_configuration_file ─────────────────────────────────────

  describe '#extract_configuration_file' do
    it 'extracts initializer metadata' do
      path = create_file('config/initializers/devise.rb', <<~RUBY)
        Devise.setup do |config|
          config.mailer_sender = 'noreply@example.com'
          config.authentication_keys = [:email]
        end
      RUBY

      unit = described_class.new.extract_configuration_file(path)

      expect(unit).not_to be_nil
      expect(unit.metadata[:config_type]).to eq('initializer')
      expect(unit.metadata[:gem_references]).to include('Devise')
      expect(unit.metadata[:config_settings]).to include('mailer_sender', 'authentication_keys')
    end

    it 'extracts environment metadata' do
      path = create_file('config/environments/production.rb', <<~RUBY)
        Rails.application.configure do
          config.cache_classes = true
          config.eager_load = true
          config.consider_all_requests_local = false
        end
      RUBY

      unit = described_class.new.extract_configuration_file(path)

      expect(unit).not_to be_nil
      expect(unit.metadata[:config_type]).to eq('environment')
      expect(unit.metadata[:rails_config_blocks]).to include('Rails.application.configure')
      expect(unit.metadata[:config_settings]).to include('cache_classes', 'eager_load')
    end

    it 'detects gem references from configure blocks' do
      path = create_file('config/initializers/sidekiq.rb', <<~RUBY)
        Sidekiq.configure_server do |config|
          config.redis = { url: 'redis://localhost:6379/0' }
        end

        Sidekiq.configure_client do |config|
          config.redis = { url: 'redis://localhost:6379/0' }
        end
      RUBY

      unit = described_class.new.extract_configuration_file(path)
      expect(unit.metadata[:gem_references]).to include('Sidekiq')
    end

    it 'detects require statements as gem references' do
      path = create_file('config/initializers/sentry.rb', <<~RUBY)
        require 'sentry-ruby'
        require 'sentry-rails'

        Sentry.config do |config|
          config.dsn = ENV['SENTRY_DSN']
        end
      RUBY

      unit = described_class.new.extract_configuration_file(path)
      expect(unit.metadata[:gem_references]).to include('sentry-ruby', 'sentry-rails', 'Sentry')
    end

    it 'excludes generic Rails config names from gem references' do
      path = create_file('config/environments/production.rb', <<~RUBY)
        Rails.application.configure do
          config.cache_classes = true
        end
      RUBY

      unit = described_class.new.extract_configuration_file(path)
      expect(unit.metadata[:gem_references]).not_to include('Rails')
    end

    it 'sets namespace to config_type' do
      path = create_file('config/initializers/cors.rb', <<~RUBY)
        # CORS config
      RUBY

      unit = described_class.new.extract_configuration_file(path)
      expect(unit.namespace).to eq('initializer')
    end

    it 'annotates source with header' do
      path = create_file('config/initializers/devise.rb', <<~RUBY)
        Devise.setup do |config|
          config.mailer_sender = 'noreply@example.com'
        end
      RUBY

      unit = described_class.new.extract_configuration_file(path)
      expect(unit.source_code).to include('Configuration: initializers/devise.rb')
      expect(unit.source_code).to include('Type: initializer')
      expect(unit.source_code).to include('Gems:')
    end

    it 'handles read errors gracefully' do
      unit = described_class.new.extract_configuration_file('/nonexistent/path.rb')
      expect(unit).to be_nil
    end

    it 'counts lines of code' do
      path = create_file('config/initializers/simple.rb', <<~RUBY)
        # A comment
        Devise.setup do |config|
          # Another comment
          config.mailer_sender = 'test@test.com'
        end
      RUBY

      unit = described_class.new.extract_configuration_file(path)
      expect(unit.metadata[:loc]).to eq(3) # Devise.setup, config.mailer_sender, end
    end
  end

  # ── Dependencies ─────────────────────────────────────────────────────

  describe 'dependency extraction' do
    it 'all dependencies have :via key' do
      path = create_file('config/initializers/devise.rb', <<~RUBY)
        Devise.setup do |config|
          config.mailer_sender = 'noreply@example.com'
        end
      RUBY

      unit = described_class.new.extract_configuration_file(path)
      unit.dependencies.each do |dep|
        expect(dep).to have_key(:via), "Dependency #{dep.inspect} missing :via key"
      end
    end

    it 'detects gem dependencies from configuration' do
      path = create_file('config/initializers/devise.rb', <<~RUBY)
        Devise.setup do |config|
          config.mailer_sender = 'noreply@example.com'
        end
      RUBY

      unit = described_class.new.extract_configuration_file(path)
      gem_deps = unit.dependencies.select { |d| d[:type] == :gem }
      expect(gem_deps.first[:target]).to eq('Devise')
      expect(gem_deps.first[:via]).to eq(:configuration)
    end

    it 'detects service dependencies' do
      path = create_file('config/initializers/custom.rb', <<~RUBY)
        NotificationService.configure do |config|
          config.enabled = true
        end
      RUBY

      unit = described_class.new.extract_configuration_file(path)
      service_deps = unit.dependencies.select { |d| d[:type] == :service }
      expect(service_deps.first[:target]).to eq('NotificationService')
    end
  end

  # ── Boot, seed and root files ───────────────────────────────────────

  describe 'boot, seed and root files' do
    def config_units
      described_class.new.extract_all.reject { |unit| unit.identifier == 'BehavioralProfile' }
    end

    it 'extracts each file with its kind' do
      {
        'config/boot.rb' => "require 'bundler/setup'\n",
        'config/environment.rb' => "require_relative 'application'\nRails.application.initialize!\n",
        'config/importmap.rb' => "pin 'application'\n",
        'config/coverage.rb' => "SimpleCov.configure do\n  add_filter '/spec/'\nend\n",
        'config/deploy.rb' => "set :application, 'ledger'\n",
        'config/deploy/production.rb' => "server 'ledger.example'\n",
        'db/seeds.rb' => "Widget.create!(name: 'seed')\n",
        'db/seeds/widgets.rb' => "Widget.create!(name: 'nested')\n",
        'Gemfile' => "source 'https://rubygems.org'\ngem 'rails'\n",
        'Rakefile' => "require_relative 'config/application'\nRails.application.load_tasks\n"
      }.each { |relative, source| create_file(relative, source) }

      kinds = config_units.to_h { |unit| [unit.identifier, unit.metadata[:config_type]] }

      expect(kinds).to eq(
        'boot.rb' => 'boot', 'environment.rb' => 'environment', 'importmap.rb' => 'importmap',
        'coverage.rb' => 'configuration', 'deploy.rb' => 'deploy', 'deploy/production.rb' => 'deploy',
        'db/seeds.rb' => 'seeds', 'db/seeds/widgets.rb' => 'seeds', 'Gemfile' => 'gemfile', 'Rakefile' => 'rakefile'
      )
    end

    it 'returns units in a stable order with initializers and environments first' do
      %w[config/initializers/b.rb config/boot.rb Gemfile config/environments/test.rb db/seeds.rb].each do |relative|
        create_file(relative, "# #{relative}\n")
      end

      expect(config_units.map(&:identifier)).to eq(
        %w[initializers/b.rb environments/test.rb Gemfile boot.rb db/seeds.rb]
      )
    end

    it 'leaves the route file and the application file to their own units' do
      create_file('config/routes.rb', "Rails.application.routes.draw {}\n")
      create_file('config/application.rb', "module Ledger; class Application < Rails::Application; end; end\n")
      create_file('config/routes/admin.rb', "resources :widgets\n")

      expect(config_units).to eq([])
      expect(described_class.new.extract_configuration_file(File.join(tmp_dir, 'config/routes.rb'))).to be_nil
      expect(described_class.new.extract_configuration_file(File.join(tmp_dir, 'config/application.rb'))).to be_nil
    end

    it 'ignores nested config directories it does not own, and non-Ruby files' do
      create_file('config/locales/en.rb', "{ en: {} }\n")
      create_file('config/settings.yml', "a: 1\n")
      create_file('lib/widget.rb', "class Widget; end\n")

      expect(config_units).to eq([])
      expect(described_class.new.extract_configuration_file(File.join(tmp_dir, 'lib/widget.rb'))).to be_nil
    end

    it 'links a Gemfile to the gems it declares' do
      path = create_file('Gemfile', <<~RUBY)
        source 'https://rubygems.org'
        gem 'rails', '~> 8.0'
        gem "sidekiq"
        # gem 'commented'
        group :test do
          gem('rspec-rails')
        end
      RUBY

      unit = described_class.new.extract_configuration_file(path)

      expect(unit.metadata[:gem_references]).to eq(%w[rails sidekiq rspec-rails])
      expect(unit.dependencies).to include({ type: :gem, target: 'rspec-rails', via: :configuration })
    end

    it 'scans a seed file for the usual dependencies' do
      path = create_file('db/seeds.rb', "WidgetSeedService.call\n")

      unit = described_class.new.extract_configuration_file(path)

      expect(unit.namespace).to eq('seeds')
      expect(unit.source_code).to include('Type: seeds', 'WidgetSeedService.call')
      expect(unit.dependencies).to include({ type: :service, target: 'WidgetSeedService', via: :code_reference })
    end

    it 'answers ownership from the path alone' do
      owned = %w[config/initializers/a.rb config/environments/test.rb config/boot.rb config/deploy/x.rb
                 db/seeds/a/b.rb Gemfile Rakefile config/puma.rb]
      unowned = %w[config/routes.rb config/application.rb config/routes/admin.rb config/settings.yml
                   config/locales/en.rb lib/tasks/a.rb Gemfile.lock db/schema.rb app/models/widget.rb]

      expect(owned.select { |path| described_class.configuration_path?(path) }).to eq(owned)
      expect(unowned.select { |path| described_class.configuration_path?(path) }).to eq([])
    end
  end
end
