# frozen_string_literal: true

require 'rails'
require 'active_record/railtie'
require 'tmpdir'
require 'fileutils'
require 'json'
require 'woods'
require 'woods/extracted_unit'
require 'woods/extractors/model_extractor'
require_relative 'objects'

# Fresh Ruby process, Rails boot, app root and SQLite database on every run.
# Post's dependent: :destroy association registers a real framework Proc.
Dir.mktmpdir('woods_model_callback_app') do |root|
  dummy = File.expand_path('../../dummy', __dir__)
  FileUtils.mkdir_p(File.join(root, 'app/models'))
  FileUtils.mkdir_p(File.join(root, 'config'))
  %w[application_record post comment].each do |name|
    FileUtils.cp(File.join(dummy, 'app/models', "#{name}.rb"), File.join(root, 'app/models'))
  end
  FileUtils.cp(File.join(dummy, 'config/database.yml'), File.join(root, 'config'))
  ENV['WOODS_DUMMY_DB'] = File.join(root, 'test.sqlite3')

  app = Class.new(Rails::Application)
  Object.const_set(:ModelCallbacksProbeApplication, app)
  app.config.root = root
  app.config.eager_load = false
  app.config.secret_key_base = 'model-callbacks-test'
  app.config.logger = Logger.new(IO::NULL)
  app.initialize!
  ActiveRecord::Base.establish_connection(:test)
  ActiveRecord::Schema.verbose = false
  ActiveRecord::Schema.define do
    create_table(:posts) { |t| t.string :title }
    create_table(:comments) { |t| t.references :post }
  end
  app.eager_load!
  object_filters = ModelCallbackObjects.register(Post)

  callback = Post._destroy_callbacks.find do |entry|
    filter = entry.respond_to?(:raw_filter) ? entry.raw_filter : entry.filter
    filter.is_a?(Proc) && filter.source_location.first.include?('active_record/associations/builder/association.rb')
  end
  raise 'Expected the Rails-generated dependent-destroy Proc' unless callback

  filter = callback.respond_to?(:raw_filter) ? callback.raw_filter : callback.filter
  unit = Woods::Extractors::ModelExtractor.new.extract_model(Post)
  # No metadata, source, dependency, chunk or hash fields are scrubbed.
  puts JSON.generate(unit: unit.to_h.except(:file_path, :extracted_at),
                     object_filters: object_filters,
                     framework_filter: "#<#{filter.lambda? ? 'lambda' : 'Proc'} #{filter.source_location.join(':')}>")
end
