# frozen_string_literal: true

# An actual fresh Rails process for provenance/boot-boundary contracts.
module SourceInputApp
  def make_source_app(app) # rubocop:disable Metrics/MethodLength -- complete executable Rails fixture
    FileUtils.cp_r(File.join(root, 'spec/dummy/.'), app)
    File.write(File.join(app, 'Rakefile'), <<~RUBY)
      require 'rake'
      require 'woods'
      task :environment do
        require 'rails'
        require 'active_record/railtie'
        require 'action_controller/railtie'
        require 'action_mailer/railtie'
        require 'active_job/railtie'
        require 'logger'
        require './config/application_config'
        ENV['WOODS_DUMMY_DB'] = File.join(Dir.pwd, 'dummy.sqlite3')
        class SourceFixtureApplication < Rails::Application
          config.root = Dir.pwd
          config.secret_key_base = 'woods-source-fixture'
          config.eager_load = false
          config.logger = Logger.new(IO::NULL)
        end
        WoodsDummyConfig.apply(SourceFixtureApplication.config, Dir.pwd)
        SourceFixtureApplication.initialize!
        ActiveRecord::Base.establish_connection(:test)
        unless ActiveRecord::Base.connection.table_exists?(:posts)
          ActiveRecord::Schema.verbose = false
          ActiveRecord::Schema.define do
            create_table(:posts) { |t| t.string :title; t.integer :status; t.timestamps }
            create_table(:comments) { |t| t.references :post; t.text :body; t.timestamps }
          end
        end
        Rails.application.eager_load!
        Woods.configuration.concurrent_extraction = false
        if ENV['WOODS_SOURCE_FAILED_SERVICE']
          require 'woods/extractors/service_extractor'
          Woods::Extractors::ServiceExtractor.prepend(Module.new do
            def extract_metadata(*)
              raise IOError, 'fixture consumer failure'
            end
          end)
        end
        if ENV['WOODS_SOURCE_BARRIER']
          File.write(File.join(Dir.pwd, 'boot-ready'), Process.pid.to_s)
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 15
          until File.exist?(File.join(Dir.pwd, 'boot-release'))
            raise 'source fixture barrier timed out' if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
            sleep 0.01
          end
        end
      end
      load #{File.join(root, 'lib/tasks/woods.rake').inspect}
    RUBY
  end
end
