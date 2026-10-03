# frozen_string_literal: true

# Boots a minimal Rails app whose controllers come from ./controllers and
# prints each extracted controller unit as one JSON line.
require 'rails'
require 'action_controller/railtie'
require 'tmpdir'
require 'fileutils'
require 'json'
require 'woods'
require 'woods/extracted_unit'
require 'woods/extractors/controller_extractor'

Dir.mktmpdir('woods_controller_runtime') do |root|
  target = File.join(root, 'app/controllers')
  FileUtils.mkdir_p(target)
  sources = Dir[File.expand_path('controllers/*.rb', __dir__)].map do |source|
    FileUtils.cp(source, target)
    File.join(target, File.basename(source))
  end

  app = Class.new(Rails::Application)
  Object.const_set(:ControllerRuntimeApplication, app)
  app.config.root = root
  app.config.eager_load = false
  app.config.secret_key_base = 'controller-runtime-test'
  app.config.logger = Logger.new(IO::NULL)
  app.initialize!
  sources.each { |path| require path }
  app.routes.draw do
    get 'health', to: 'health#show'
    get 'ping', to: 'ping#index'
  end

  Woods::Extractors::ControllerExtractor.new.extract_all.sort_by(&:identifier).each do |unit|
    puts JSON.generate(unit.to_h.except(:file_path, :extracted_at))
  end
end
