# frozen_string_literal: true

ENV['RAILS_ENV'] = 'test'

require 'rails'
require 'active_record/railtie'
require 'action_controller/railtie'
require 'active_job/railtie'
require 'active_model_serializers'
require 'tmpdir'
require 'fileutils'
require 'json'
require 'woods'
require 'woods/extractor'
require 'woods/mcp/index_reader'
require_relative '../../support/index_comparison'

def write(root, path, source)
  absolute = File.join(root, path)
  FileUtils.mkdir_p(File.dirname(absolute))
  File.write(absolute, source)
  absolute
end

def verify(name)
  raise name unless yield
end

Dir.mktmpdir('woods_incremental_runtime') do |root|
  database = File.join(root, 'database.sqlite3')
  write(root, 'config/database.yml', JSON.generate('test' => { adapter: 'sqlite3', database: database }))
  write(root, 'config/application.rb', '# application boot input')
  write(root, 'app/controllers/application_controller.rb', 'class ApplicationController < ActionController::API; end')
  write(root, 'app/jobs/application_job.rb', 'class ApplicationJob < ActiveJob::Base; end')
  write(root, 'app/models/post.rb', 'class Post < ActiveRecord::Base; end')
  write(root, 'config/routes.rb', "Rails.application.routes.draw { get '/items', to: 'container#index' }")
  job = write(root, 'app/jobs/outer_job.rb', <<~RUBY)
    class OuterJob < ApplicationJob
      def perform; :before; end
      class NestedJob < ApplicationJob
        def perform; :before; end
      end
    end
  RUBY
  serializer = write(root, 'app/serializers/outer_serializer.rb', <<~RUBY)
    class OuterSerializer < ActiveModel::Serializer
      attributes :id
      class NestedSerializer < ActiveModel::Serializer
        attributes :id
      end
    end
  RUBY
  controller = write(root, 'app/controllers/container_controller.rb', <<~RUBY)
    class ContainerController < ApplicationController
      def index; head :ok; end
      class ItemSerializer < ActiveModel::Serializer
        attributes :id
      end
    end
  RUBY
  container = write(root, 'app/models/job_container.rb', <<~RUBY)
    class JobContainer
      class OldJob < ApplicationJob
        def perform; :before; end
      end
    end
  RUBY
  app = Class.new(Rails::Application)
  Object.const_set(:IncrementalRuntimeApplication, app)
  app.config.root = root
  app.config.api_only = true
  app.config.eager_load = false
  app.config.cache_classes = false
  app.config.secret_key_base = 'incremental-runtime-fixture'
  app.config.logger = Logger.new(IO::NULL)
  app.initialize!
  ActiveRecord::Base.establish_connection(adapter: 'sqlite3', database: database)
  ActiveRecord::Schema.verbose = false
  ActiveRecord::Schema.define { create_table(:posts) { |table| table.string :title } }
  Rails.application.eager_load!
  Woods.configure do |config|
    config.concurrent_extraction = false
    config.enable_snapshots = false
    config.include_framework_sources = false
  end
  output = File.join(root, 'tmp/index')
  runner = Woods::Extractor.new(output_dir: output)
  runner.extract_all
  reader = Woods::MCP::IndexReader.new(output)
  expected = { 'OuterJob::NestedJob' => 'job', 'OuterSerializer::NestedSerializer' => 'serializer',
               'ContainerController::ItemSerializer' => 'serializer', 'JobContainer::OldJob' => 'job' }
  verify('full extraction discovers nested runtime units') do
    expected.all? { |name, type| reader.find_unit(name, type: type) }
  end
  [job, serializer, controller].each { |path| File.write(path, "#{File.read(path)}\n# changed\n") }
  File.write(container, File.read(container).sub('OldJob', 'AddedJob'))
  Rails.application.reloader.reload!
  runner.extract_changed([job, serializer, controller, container])
  runner.raise_on_publication_failure!
  verify('incremental retains nested units and reconciles model-owned jobs without phantom wrappers') do
    expected.except('JobContainer::OldJob').all? { |name, type| reader.find_unit(name, type: type) } &&
      reader.find_unit('JobContainer::AddedJob', type: 'job') &&
      !reader.find_unit('JobContainer::OldJob', type: 'job') &&
      !reader.find_unit('ContainerController', type: 'serializer') &&
      !reader.find_unit('JobContainer', type: 'job')
  end
  compare = lambda do |label|
    Dir.mktmpdir('runtime_oracle') do |oracle|
      Woods::Extractor.new(output_dir: oracle).extract_all
      differences = IndexComparison.differences(output, oracle)
      raise "#{label}: #{differences.inspect}" unless differences.empty?
    end
  end
  compare.call('full/incremental published JSON and graph equivalence')
  runner.refresh(:jobs, :serializers)
  runner.raise_on_publication_failure!
  compare.call('full/refresh published JSON and graph equivalence')

  # A runtime refresh must reach the synthetic profile's real extractor.
  Rails.application.config.time_zone = 'Hawaii'
  runner.refresh(:configurations)
  verify('configuration refresh has no nominal-filename phantom') do
    reader.find_unit('BehavioralProfile', type: 'configuration').dig('metadata', 'behavior_flags',
                                                                     'time_zone') == 'Hawaii' &&
      !reader.find_unit('application.rb', type: 'configuration')
  end
  compare.call('profile full/refresh equivalence')
  verify('serializer entry point refuses the controller wrapper') do
    Woods::Extractors::SerializerExtractor.new.extract_serializer_class(ContainerController).nil?
  end

  previous_token = Woods::Generation.new(output_dir: output).current.token
  descendants = ActiveModel::Serializer.method(:descendants)
  ActiveModel::Serializer.define_singleton_method(:descendants) { raise 'serializer inventory unavailable' }
  begin
    runner.extract_changed([serializer])
    raise 'accepted failed serializer discovery'
  rescue Woods::ExtractionError => e
    raise unless e.message.include?('serializers')
  ensure
    ActiveModel::Serializer.define_singleton_method(:descendants, &descendants)
  end
  verify('failed discovery preserves the published generation') do
    Woods::Generation.new(output_dir: output).current.token == previous_token
  end
  puts JSON.generate('checks' => ['nested jobs and serializers', 'runtime additions and removals',
                                  'full/incremental/refresh equivalence', 'resolved behavioral profile',
                                  'failed discovery preserves publication'])
end
