# frozen_string_literal: true

# Boots a minimal Rails app whose controllers inherit filters from
# ApplicationController and a concern, skip one with a narrower scope, and
# guard others with if/unless conditions, plus a mailer with a scoped
# callback. Prints the published filter metadata (W-8) as one JSON line.
require 'rails'
require 'action_controller/railtie'
require 'action_mailer/railtie'
require 'tmpdir'
require 'fileutils'
require 'json'
require 'woods'
require 'woods/extracted_unit'
require 'woods/extractors/controller_extractor'
require 'woods/extractors/mailer_extractor'

Dir.mktmpdir('woods_filter_applicability') do |root|
  sources = Dir[File.expand_path('app/**/*.rb', __dir__)].map do |source|
    target = File.join(root, source.delete_prefix("#{__dir__}/"))
    FileUtils.mkdir_p(File.dirname(target))
    FileUtils.cp(source, target)
    target
  end

  app = Class.new(Rails::Application)
  Object.const_set(:FilterApplicabilityApplication, app)
  app.config.root = root
  app.config.eager_load = false
  app.config.secret_key_base = 'filter-applicability-test'
  app.config.logger = Logger.new(IO::NULL)
  app.initialize!
  sources.sort_by { |path| [path.include?('/concerns/') ? 0 : 1, path.end_with?('application_controller.rb') ? 0 : 1] }
         .each { |path| require path }
  app.routes.draw do
    resources :articles, only: %i[index show edit]
    get 'articles/health', to: 'articles#health'
    resources :drafts, only: %i[show edit]
  end

  controllers = Woods::Extractors::ControllerExtractor.new.extract_all
  mailers = Woods::Extractors::MailerExtractor.new.extract_all
  units = (controllers + mailers).to_h { |unit| [unit.identifier, unit.to_h.except(:file_path, :extracted_at)] }
  puts JSON.generate('rails' => Rails.version, 'units' => units)
end
