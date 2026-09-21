# frozen_string_literal: true

require 'logger'
require 'rails'
require 'active_record/railtie'
require 'tmpdir'
require 'fileutils'
require 'json'
require 'woods'
require 'woods/extracted_unit'
require 'woods/extractors/model_extractor'

Dir.mktmpdir('woods_validation_options') do |root|
  FileUtils.mkdir_p(File.join(root, 'app/models'))
  FileUtils.mkdir_p(File.join(root, 'config'))
  path = File.join(root, 'app/models/validation_item.rb')
  FileUtils.cp(File.expand_path('validation_item.rb', __dir__), path)
  database = { adapter: 'sqlite3', database: ':memory:' }
  File.write(File.join(root, 'config/database.yml'), JSON.generate(Rails.env => database))
  app = Class.new(Rails::Application)
  Object.const_set(:ValidationOptionsApplication, app)
  app.config.root = root
  app.config.eager_load = false
  app.config.secret_key_base = 'validation-options-fixture'
  app.config.logger = Logger.new(IO::NULL)
  app.initialize!
  ActiveRecord::Base.establish_connection(database)
  ActiveRecord::Schema.verbose = false
  ActiveRecord::Schema.define { create_table(:validation_items) { |table| table.string :status } }
  require path

  if ENV['VALIDATION_PUBLISH'] == '1'
    require_relative 'published'
    puts JSON.generate(ValidationPublicationProbe.call(root, path))
  else
    unit = Woods::Extractors::ModelExtractor.new.extract_model(ValidationItem)
    raise 'model was not extracted' unless unit

    puts JSON.generate(unit.to_h.except(:file_path, :extracted_at))
  end
end
