# frozen_string_literal: true

require 'rails'
require 'action_controller/railtie'
require 'tmpdir'
require 'json'
require 'woods'
require 'woods/extracted_unit'
require 'woods/extractors/middleware_extractor'

class MiddlewareProbe
  def initialize(app, *)
    @app = app
  end

  def call(env)
    @app.call(env)
  end
end

begin
  root = File.expand_path('../../dummy', __dir__)
  class MiddlewareProbeApplication < Rails::Application
    config.eager_load = false
    config.secret_key_base = 'middleware-test'
    config.logger = Logger.new(IO::NULL)
  end
  app = MiddlewareProbeApplication
  app.config.root = root
  app.config.hosts = ['example.test']
  app.config.middleware.use MiddlewareProbe,
                            { literal: '#<Thing:0x123abc>', setting: ENV.fetch('MIDDLEWARE_SETTING', 'first'),
                              executor: Class.new(ActiveSupport::Executor), callback: -> { :test } }
  app.config.middleware.use MiddlewareProbe, app.instance, app.instance.routes
  app.initialize!
  unit = Woods::Extractors::MiddlewareExtractor.new.extract_all.fetch(0)
  puts JSON.generate(metadata: unit.metadata, source: unit.source_code, hash: unit.to_h[:source_hash])
end
