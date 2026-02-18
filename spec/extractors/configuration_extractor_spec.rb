# frozen_string_literal: true

require 'spec_helper'
require 'set'
require 'tmpdir'
require 'fileutils'
require 'active_support/core_ext/object/blank'
require 'codebase_index/extractors/configuration_extractor'

RSpec.describe CodebaseIndex::Extractors::ConfigurationExtractor do
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
end
