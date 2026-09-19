# frozen_string_literal: true

require 'logger'
require 'rails'
require 'action_controller/railtie'
require 'action_mailer/railtie'
require 'active_record/railtie' if ENV['MAILER_PUBLISH'] == '1'
require 'tmpdir'
require 'fileutils'
require 'json'
require 'woods'
require 'woods/extracted_unit'
require 'woods/extractors/mailer_extractor'

Dir.mktmpdir('woods_mailer_determinism') do |root|
  FileUtils.mkdir_p(File.join(root, 'app/mailers'))
  mailer_path = File.join(root, 'app/mailers/stable_mailer.rb')
  FileUtils.cp(File.expand_path('stable_mailer.rb', __dir__), mailer_path)
  if ENV['MAILER_PUBLISH'] == '1'
    FileUtils.mkdir_p(File.join(root, 'config'))
    database = { adapter: 'sqlite3', database: ':memory:' }
    File.write(File.join(root, 'config/database.yml'), JSON.generate(Rails.env => database))
  end
  app = Class.new(Rails::Application)
  Object.const_set(:MailerDeterminismApplication, app)
  app.config.root = root
  app.config.eager_load = false
  app.config.secret_key_base = 'mailer-determinism-test'
  app.config.logger = Logger.new(IO::NULL)
  app.initialize!
  require mailer_path

  unit = Woods::Extractors::MailerExtractor.new.extract_all.find { |item| item.identifier == 'StableMailer' }
  raise 'mailer was not extracted' unless unit

  if ENV['MAILER_PUBLISH'] == '1'
    require_relative 'published'
    puts JSON.generate(MailerPublicationProbe.call(root, mailer_path))
  else
    puts JSON.generate(unit.to_h.except(:file_path, :extracted_at))
  end
end
