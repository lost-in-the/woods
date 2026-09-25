# frozen_string_literal: true

ENV['RAILS_ENV'] = 'test'
require 'logger'
require 'rails'
require 'active_record/railtie'
require 'action_controller/railtie'
require 'tmpdir'
require 'fileutils'
require 'json'
require 'woods'
require 'woods/extractor'
require 'woods/mcp/index_reader'

def write(root, path, content)
  file = File.join(root, path)
  FileUtils.mkdir_p(File.dirname(file))
  File.write(file, content)
end

Dir.mktmpdir('woods-library-identity') do |root|
  write(root, 'config/database.yml', JSON.generate('test' => { adapter: 'sqlite3', database: ':memory:' }))
  write(root, 'app/controllers/application_controller.rb', 'class ApplicationController < ActionController::API; end')
  write(root, 'app/controllers/errors_controller.rb', <<~RUBY)
    class ErrorsController < ApplicationController
      def show
        raise Acme::Error, 'example'
      end
    end
  RUBY
  write(root, 'lib/acme.rb', 'module Acme; VERSION = "1"; end')
  error_source = 'module Acme; class Error < StandardError; end; end'
  error_source = error_source.gsub('; ', "\n") if ARGV.fetch(0) == 'multiline'
  write(root, 'lib/acme/error.rb', error_source)
  write(root, 'lib/extensions/template.rb', <<~RUBY)
    module Templates; TEXT = <<~TEXT; end
      module Pretend
      class Example
    TEXT
  RUBY

  app = Class.new(Rails::Application)
  Object.const_set(:LibraryIdentityApplication, app)
  app.config.root = root
  app.config.api_only = true
  app.config.eager_load = false
  app.config.secret_key_base = 'library-identity-fixture'
  app.config.logger = Logger.new(IO::NULL)
  app.initialize!
  ActiveRecord::Base.establish_connection(adapter: 'sqlite3', database: ':memory:')
  Rails.application.eager_load!
  # The host loads these unmanaged libraries; extraction must not evaluate them.
  %w[acme.rb acme/error.rb extensions/template.rb].each { |file| require File.join(root, 'lib', file) }
  Woods.configure do |config|
    config.concurrent_extraction = false
    config.enable_snapshots = false
    config.include_framework_sources = false
  end
  output = File.join(root, 'tmp/index')
  runner = Woods::Extractor.new(output_dir: output)
  runner.extract_all
  runner.raise_on_publication_failure!
  reader = Woods::MCP::IndexReader.new(output)
  payload = Woods::Generation.new(output_dir: output).payload_dir
  libraries = JSON.parse(File.read(File.join(payload, 'libs/_index.json')))
  error = reader.find_unit('Acme::Error', type: 'lib')
  controller = reader.find_unit('ErrorsController', type: 'controller')
  puts JSON.generate(identifiers: libraries.map { |unit| unit.fetch('identifier') },
                     error_parent: error&.dig('metadata', 'parent_class'),
                     dependencies: controller.fetch('dependencies'))
end
