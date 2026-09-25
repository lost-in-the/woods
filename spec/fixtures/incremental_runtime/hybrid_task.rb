# frozen_string_literal: true

# Two fresh processes share an index; only the indirect queue input changes.
ENV['RAILS_ENV'] = 'test'
root, phase = ARGV
require 'rails'
require 'active_record/railtie'
require 'action_controller/railtie'
require 'active_job/railtie'
require 'rake'
require 'json'
require 'fileutils'
require 'tmpdir'
require 'woods'
require 'woods/extractor'
require 'woods/mcp/index_reader'

def write(root, path, source)
  absolute = File.join(root, path)
  FileUtils.mkdir_p(File.dirname(absolute))
  File.write(absolute, source)
end

database = File.join(root, 'database.sqlite3')
write(root, 'config/database.yml', JSON.generate('test' => { adapter: 'sqlite3', database: database }))
write(root, 'config/application.rb', '# stable application boot input')
write(root, 'app/controllers/application_controller.rb', 'class ApplicationController < ActionController::API; end')
write(root, 'app/jobs/application_job.rb', 'class ApplicationJob < ActiveJob::Base; end')
write(root, 'app/models/queue_settings.rb', "class QueueSettings; NAME = '#{phase}'; end")
write(root, 'app/models/job_container.rb', <<~RUBY)
  class JobContainer
    class NotifyJob < ApplicationJob
      queue_as QueueSettings::NAME
      def perform; end
    end
  end
RUBY
app = Class.new(Rails::Application)
Object.const_set(:HybridTaskApplication, app)
app.config.root = root
app.config.api_only = true
app.config.eager_load = false
app.config.secret_key_base = 'hybrid-task-fixture'
app.config.logger = Logger.new(IO::NULL)
app.initialize!
ActiveRecord::Base.establish_connection(adapter: 'sqlite3', database: database)
Rails.application.eager_load!
Woods.configure do |config|
  config.concurrent_extraction = false
  config.enable_snapshots = false
  config.include_framework_sources = false
end
output = File.join(root, 'tmp/index')
ENV['WOODS_OUTPUT'] = output
ENV['WOODS_IGNORE_WATCH'] = '1'
ENV['CHANGED_FILES'] = 'app/models/queue_settings.rb'
Rake::Task.define_task(:environment)
load File.expand_path('../../../lib/tasks/woods.rake', __dir__)
Rake::Task[phase == 'before' ? 'woods:extract' : 'woods:incremental'].invoke
reader = Woods::MCP::IndexReader.new(output)
indexed = reader.find_unit('JobContainer::NotifyJob', type: 'job').dig('metadata', 'queue')
Dir.mktmpdir('hybrid_oracle') do |oracle|
  Woods::Extractor.new(output_dir: oracle).tap do |runner|
    runner.extract_all
    runner.raise_on_publication_failure!
  end
  full = Woods::MCP::IndexReader.new(oracle).find_unit('JobContainer::NotifyJob', type: 'job').dig('metadata', 'queue')
  puts JSON.generate(live: JobContainer::NotifyJob.queue_name, indexed: indexed, full: full,
                     generation: Woods::Generation.new(output_dir: output).current.number)
end
