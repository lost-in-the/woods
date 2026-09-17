# frozen_string_literal: true

require 'rails'
require 'action_controller/railtie'
require 'tmpdir'
require 'fileutils'
require 'json'
require 'woods'
require 'woods/extracted_unit'
require 'woods/extractors/controller_extractor'

# Every boot has a different app root, exercising checkout-path portability too.
Dir.mktmpdir('woods_callback_app') do |root|
  FileUtils.mkdir_p(File.join(root, 'app/controllers'))
  controller_path = File.join(root, 'app/controllers/callbacks_controller.rb')
  FileUtils.cp(File.expand_path('callbacks_controller.rb', __dir__), controller_path)
  app = Class.new(Rails::Application)
  Object.const_set(:CallbacksProbeApplication, app)
  app.config.root = root
  app.config.eager_load = false
  app.config.secret_key_base = 'callbacks-test'
  app.config.logger = Logger.new(IO::NULL)
  app.initialize!
  require controller_path

  unit = Woods::Extractors::ControllerExtractor.new.extract_all.find do |candidate|
    candidate.identifier == 'CallbacksController'
  end
  # Only publication time and the expected absolute file path are variable.
  puts JSON.generate(unit.to_h.except(:file_path, :extracted_at))
end
