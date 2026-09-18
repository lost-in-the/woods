# frozen_string_literal: true

require 'logger'
require 'rails'
require 'active_record/railtie'
require 'action_controller/railtie'
require 'active_job/railtie'
require 'action_mailer/railtie' unless ENV['MAILER_MODE'] == 'absent'
require 'tmpdir'
require 'fileutils'
require 'json'
require 'woods'
require 'woods/extractor'
require 'woods/resilience/index_validator'
require 'woods/mcp/index_reader'

Dir.mktmpdir('woods_optional_mailer') do |root|
  FileUtils.mkdir_p(File.join(root, 'app/controllers'))
  FileUtils.mkdir_p(File.join(root, 'config'))
  database = { adapter: 'sqlite3', database: ':memory:' }
  File.write(File.join(root, 'config/database.yml'), JSON.generate(Rails.env => database))
  File.write(File.join(root, 'app/controllers/application_controller.rb'),
             'class ApplicationController < ActionController::API; end')
  if ENV['MAILER_MODE'] == 'app'
    FileUtils.mkdir_p(File.join(root, 'app/mailers'))
    File.write(File.join(root, 'app/mailers/local_mailer.rb'),
               'class LocalMailer < ActionMailer::Base; def greeting; end; end')
  end
  app = Class.new(Rails::Application)
  Object.const_set(:OptionalMailerApplication, app)
  app.config.root = root
  app.config.api_only = true
  app.config.eager_load = false
  app.config.secret_key_base = 'optional-mailer-test'
  app.config.logger = Logger.new(IO::NULL)
  app.initialize!
  ActiveRecord::Base.establish_connection(adapter: 'sqlite3', database: ':memory:')
  unless ENV['MAILER_MODE'] == 'absent'
    # This fixture is outside Rails.root, like a dependency's mailer class.
    require File.expand_path('foreign_mailer.rb', __dir__)
  end
  raise 'Absent-mailer fixture loaded ActionMailer' if ENV['MAILER_MODE'] == 'absent' && defined?(ActionMailer)

  output = File.join(root, 'tmp/woods')
  extractor = Woods::Extractor.new(output_dir: output)
  extractor.extract_all
  report = Woods::Resilience::IndexValidator.new(index_dir: output, app_root: root).validate
  mailers = Woods::Extractors::MailerExtractor.new
  puts JSON.generate(
    valid: report.valid?, errors: report.errors,
    framework_loaded: !defined?(ActionMailer).nil?,
    published: Woods::MCP::IndexReader.new(output).list_units(type: 'mailer').map { |unit|
      unit.fetch('identifier')
    }.sort,
    discoverable: mailers.discoverable_classes.map(&:name).sort,
    extracted: mailers.extract_all.map(&:identifier).sort
  )
end
