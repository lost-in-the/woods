# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'active_support/core_ext/object/blank'
require 'active_support/core_ext/string/inflections'
require 'codebase_index/model_name_cache'
require 'codebase_index/extractors/shared_utility_methods'
require 'codebase_index/extractors/shared_dependency_scanner'
require 'codebase_index/extractors/lib_extractor'

RSpec.describe CodebaseIndex::Extractors::LibExtractor do
  include_context 'extractor setup'

  # ── Initialization ───────────────────────────────────────────────────

  describe '#initialize' do
    it 'handles missing lib directory gracefully' do
      extractor = described_class.new
      expect(extractor.extract_all).to eq([])
    end
  end

  # ── extract_all ──────────────────────────────────────────────────────

  describe '#extract_all' do
    it 'discovers files in lib/' do
      create_file('lib/theme_upgrader.rb', <<~RUBY)
        class ThemeUpgrader
          def call(theme); end
        end
      RUBY

      units = described_class.new.extract_all
      expect(units.size).to eq(1)
      expect(units.first.type).to eq(:lib)
      expect(units.first.identifier).to eq('ThemeUpgrader')
    end

    it 'discovers files in nested lib subdirectories' do
      create_file('lib/external/analytics.rb', <<~RUBY)
        module External
          class Analytics
            def track(event); end
          end
        end
      RUBY

      units = described_class.new.extract_all
      expect(units.size).to eq(1)
      expect(units.first.identifier).to eq('External::Analytics')
    end

    it 'collects units across multiple files' do
      create_file('lib/theme_upgrader.rb', 'class ThemeUpgrader; end')
      create_file('lib/json_api/serializer.rb', 'class JsonApi::Serializer; end')
      create_file('lib/external/client.rb', 'class External::Client; end')

      units = described_class.new.extract_all
      expect(units.size).to eq(3)
    end

    it 'skips files in lib/tasks/' do
      create_file('lib/tasks/maintenance.rake', <<~RUBY)
        namespace :maintenance do
          task cleanup: :environment do
            puts "cleaning"
          end
        end
      RUBY
      create_file('lib/tasks/export.rb', 'class ExportTask; end')
      create_file('lib/utilities.rb', 'class Utilities; end')

      units = described_class.new.extract_all
      identifiers = units.map(&:identifier)
      expect(identifiers).to include('Utilities')
      expect(identifiers).not_to include('ExportTask')
    end

    it 'skips files in lib/generators/' do
      create_file('lib/generators/install_generator.rb', <<~RUBY)
        class InstallGenerator < Rails::Generators::Base
          def generate; end
        end
      RUBY
      create_file('lib/utilities.rb', 'class Utilities; end')

      units = described_class.new.extract_all
      identifiers = units.map(&:identifier)
      expect(identifiers).to include('Utilities')
      expect(identifiers).not_to include('InstallGenerator')
    end

    it 'handles a completely empty lib directory' do
      FileUtils.mkdir_p(File.join(tmp_dir, 'lib'))
      units = described_class.new.extract_all
      expect(units).to eq([])
    end
  end

  # ── extract_lib_file ─────────────────────────────────────────────────

  describe '#extract_lib_file' do
    it 'extracts a plain Ruby class' do
      path = create_file('lib/theme_upgrader.rb', <<~RUBY)
        class ThemeUpgrader
          def call(theme)
            theme.upgrade!
          end
        end
      RUBY

      unit = described_class.new.extract_lib_file(path)
      expect(unit).not_to be_nil
      expect(unit.type).to eq(:lib)
      expect(unit.identifier).to eq('ThemeUpgrader')
      expect(unit.file_path).to eq(path)
    end

    it 'extracts a module-only file' do
      path = create_file('lib/json_api.rb', <<~RUBY)
        module JsonApi
          MEDIA_TYPE = 'application/vnd.api+json'
        end
      RUBY

      unit = described_class.new.extract_lib_file(path)
      expect(unit).not_to be_nil
      expect(unit.type).to eq(:lib)
      expect(unit.identifier).to eq('JsonApi')
    end

    it 'extracts a namespaced class inside module blocks' do
      path = create_file('lib/external/analytics.rb', <<~RUBY)
        module External
          class Analytics
            def track(event); end
          end
        end
      RUBY

      unit = described_class.new.extract_lib_file(path)
      expect(unit.identifier).to eq('External::Analytics')
      expect(unit.namespace).to eq('External')
    end

    it 'extracts a class with an explicit namespace qualifier' do
      path = create_file('lib/json_api/serializer.rb', <<~RUBY)
        class JsonApi::Serializer
          def serialize(resource); end
        end
      RUBY

      unit = described_class.new.extract_lib_file(path)
      expect(unit.identifier).to eq('JsonApi::Serializer')
      expect(unit.namespace).to eq('JsonApi')
    end

    it 'sets namespace to nil for top-level classes' do
      path = create_file('lib/utilities.rb', 'class Utilities; end')
      unit = described_class.new.extract_lib_file(path)
      expect(unit.namespace).to be_nil
    end

    it 'sets source_code with annotation header' do
      path = create_file('lib/theme_upgrader.rb', <<~RUBY)
        class ThemeUpgrader
          def call; end
        end
      RUBY

      unit = described_class.new.extract_lib_file(path)
      expect(unit.source_code).to include('# ║ Lib: ThemeUpgrader')
      expect(unit.source_code).to include('def call')
    end

    it 'returns nil for a non-existent file' do
      unit = described_class.new.extract_lib_file('/nonexistent/path.rb')
      expect(unit).to be_nil
    end

    it 'returns nil for an empty file' do
      path = create_file('lib/empty.rb', '')
      unit = described_class.new.extract_lib_file(path)
      expect(unit).to be_nil
    end

    it 'returns nil for a file with only whitespace' do
      path = create_file('lib/blank.rb', "   \n\n  ")
      unit = described_class.new.extract_lib_file(path)
      expect(unit).to be_nil
    end

    it 'includes all dependencies with :via key' do
      path = create_file('lib/notification_sender.rb', <<~RUBY)
        class NotificationSender
          def send_all
            UserMailer.notification.deliver_later
            AlertJob.perform_later(id)
          end
        end
      RUBY

      unit = described_class.new.extract_lib_file(path)
      unit.dependencies.each do |dep|
        expect(dep).to have_key(:via), "Dependency #{dep.inspect} missing :via key"
      end
    end

    it_behaves_like 'all dependencies have :via key',
                    :extract_lib_file,
                    'lib/notification_sender.rb',
                    <<~RUBY
                      class NotificationSender
                        def run
                          UserMailer.notify.deliver_later
                        end
                      end
                    RUBY
  end

  # ── Metadata ─────────────────────────────────────────────────────────

  describe 'metadata' do
    it 'includes public_methods' do
      path = create_file('lib/theme_upgrader.rb', <<~RUBY)
        class ThemeUpgrader
          def call(theme); end
          def preview(theme); end

          private

          def validate!(theme); end
        end
      RUBY

      unit = described_class.new.extract_lib_file(path)
      expect(unit.metadata[:public_methods]).to include('call', 'preview')
      expect(unit.metadata[:public_methods]).not_to include('validate!')
    end

    it 'includes class_methods' do
      path = create_file('lib/theme_upgrader.rb', <<~RUBY)
        class ThemeUpgrader
          def self.upgrade_all(themes)
            themes.each { |t| new.call(t) }
          end
        end
      RUBY

      unit = described_class.new.extract_lib_file(path)
      expect(unit.metadata[:class_methods]).to include('upgrade_all')
    end

    it 'includes initialize_params' do
      path = create_file('lib/external/client.rb', <<~RUBY)
        class External::Client
          def initialize(api_key:, timeout: 30)
            @api_key = api_key
            @timeout = timeout
          end
        end
      RUBY

      unit = described_class.new.extract_lib_file(path)
      expect(unit.metadata[:initialize_params]).not_to be_empty
      names = unit.metadata[:initialize_params].map { |p| p[:name] }
      expect(names).to include('api_key', 'timeout')
    end

    it 'includes parent_class when present' do
      path = create_file('lib/application_middleware.rb', <<~RUBY)
        class ApplicationMiddleware < ActionDispatch::Middleware
          def call(env); end
        end
      RUBY

      unit = described_class.new.extract_lib_file(path)
      expect(unit.metadata[:parent_class]).to eq('ActionDispatch::Middleware')
    end

    it 'sets parent_class to nil for classes without explicit parent' do
      path = create_file('lib/utilities.rb', 'class Utilities; end')
      unit = described_class.new.extract_lib_file(path)
      expect(unit.metadata[:parent_class]).to be_nil
    end

    it 'includes loc count' do
      path = create_file('lib/theme_upgrader.rb', <<~RUBY)
        class ThemeUpgrader
          def call(theme)
            theme.upgrade!
          end
        end
      RUBY

      unit = described_class.new.extract_lib_file(path)
      expect(unit.metadata[:loc]).to be_a(Integer)
      expect(unit.metadata[:loc]).to be > 0
    end

    it 'includes method_count' do
      path = create_file('lib/theme_upgrader.rb', <<~RUBY)
        class ThemeUpgrader
          def call; end
          def preview; end
          def self.upgrade_all; end
        end
      RUBY

      unit = described_class.new.extract_lib_file(path)
      expect(unit.metadata[:method_count]).to eq(3)
    end

    it 'includes entry_points for call method' do
      path = create_file('lib/theme_upgrader.rb', <<~RUBY)
        class ThemeUpgrader
          def call(theme); end
        end
      RUBY

      unit = described_class.new.extract_lib_file(path)
      expect(unit.metadata[:entry_points]).to include('call')
    end

    it 'includes entry_points for perform, execute, run, process methods' do
      path = create_file('lib/batch_processor.rb', <<~RUBY)
        class BatchProcessor
          def perform(items); end
          def execute(cmd); end
          def run; end
          def process(record); end
        end
      RUBY

      unit = described_class.new.extract_lib_file(path)
      expect(unit.metadata[:entry_points]).to include('perform', 'execute', 'run', 'process')
    end

    it 'sets entry_points to ["unknown"] when no known entry point is defined' do
      path = create_file('lib/utilities.rb', <<~RUBY)
        class Utilities
          def helper_method; end
        end
      RUBY

      unit = described_class.new.extract_lib_file(path)
      expect(unit.metadata[:entry_points]).to eq(['unknown'])
    end

    it 'includes all expected metadata keys' do
      path = create_file('lib/utilities.rb', 'class Utilities; end')
      unit = described_class.new.extract_lib_file(path)
      meta = unit.metadata

      expect(meta).to have_key(:public_methods)
      expect(meta).to have_key(:class_methods)
      expect(meta).to have_key(:initialize_params)
      expect(meta).to have_key(:parent_class)
      expect(meta).to have_key(:loc)
      expect(meta).to have_key(:method_count)
      expect(meta).to have_key(:entry_points)
    end
  end

  # ── Dependencies ─────────────────────────────────────────────────────

  describe 'dependencies' do
    it 'detects service dependencies' do
      path = create_file('lib/report_generator.rb', <<~RUBY)
        class ReportGenerator
          def generate
            DataService.fetch_all
          end
        end
      RUBY

      unit = described_class.new.extract_lib_file(path)
      dep = unit.dependencies.find { |d| d[:type] == :service && d[:target] == 'DataService' }
      expect(dep).not_to be_nil
    end

    it 'detects job dependencies' do
      path = create_file('lib/export_runner.rb', <<~RUBY)
        class ExportRunner
          def run
            ExportJob.perform_later(id)
          end
        end
      RUBY

      unit = described_class.new.extract_lib_file(path)
      dep = unit.dependencies.find { |d| d[:type] == :job && d[:target] == 'ExportJob' }
      expect(dep).not_to be_nil
    end

    it 'detects mailer dependencies' do
      path = create_file('lib/notification_sender.rb', <<~RUBY)
        class NotificationSender
          def notify
            UserMailer.alert.deliver_later
          end
        end
      RUBY

      unit = described_class.new.extract_lib_file(path)
      dep = unit.dependencies.find { |d| d[:type] == :mailer && d[:target] == 'UserMailer' }
      expect(dep).not_to be_nil
    end

    it 'returns empty dependencies for a simple class with no references' do
      path = create_file('lib/utilities.rb', <<~RUBY)
        class Utilities
          def format(value)
            value.to_s
          end
        end
      RUBY

      unit = described_class.new.extract_lib_file(path)
      expect(unit.dependencies).to be_an(Array)
      expect(unit.dependencies).to be_empty
    end
  end

  # ── Serialization round-trip ─────────────────────────────────────────

  describe 'serialization' do
    it 'to_h round-trips correctly' do
      path = create_file('lib/theme_upgrader.rb', <<~RUBY)
        class ThemeUpgrader
          def call(theme)
            theme.upgrade!
          end
        end
      RUBY

      unit = described_class.new.extract_lib_file(path)
      hash = unit.to_h

      expect(hash[:type]).to eq(:lib)
      expect(hash[:identifier]).to eq('ThemeUpgrader')
      expect(hash[:source_code]).to include('ThemeUpgrader')
      expect(hash[:source_hash]).to be_a(String)
      expect(hash[:extracted_at]).to be_a(String)

      json = JSON.generate(hash)
      parsed = JSON.parse(json)
      expect(parsed['type']).to eq('lib')
      expect(parsed['identifier']).to eq('ThemeUpgrader')
    end
  end
end
