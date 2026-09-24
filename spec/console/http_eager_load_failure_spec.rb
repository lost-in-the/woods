# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'open3'
require 'json'

RSpec.describe 'HTTP Console with a real Rails eager-load failure', :booted_app do
  it 'keeps the endpoint unavailable until restart while preserving the guarded Rails stack' do
    Dir.mktmpdir('woods-console-eager-load') do |directory|
      FileUtils.mkdir_p(File.join(directory, 'app/models'))
      FileUtils.mkdir_p(File.join(directory, 'config'))
      File.write(File.join(directory, 'config/database.yml'), "test:\n  adapter: sqlite3\n  database: ':memory:'\n")
      File.write(File.join(directory, 'app/models/broken_model.rb'), <<~RUBY)
        class BrokenModel < MissingApplicationModelBase
        end
      RUBY
      script = <<~'RUBY'
        require 'logger'
        require 'rails'
        require 'active_record/railtie'
        require 'action_controller/railtie'
        require 'rack/mock'
        require 'woods'
        Woods.configure do |config|
          config.console_mcp_enabled = true
          config.console_mcp_http_enabled = true
          config.console_mcp_token = 'woods-fixture-token-with-32-characters'
        end
        class ConsoleFailureApplication < Rails::Application
          config.eager_load = false
          config.cache_classes = true
          config.secret_key_base = 'woods-console-load-fixture'
          config.logger = Logger.new(IO::NULL)
          config.hosts = []
          config.consider_all_requests_local = false
          config.action_dispatch.show_exceptions = false
        end
        ConsoleFailureApplication.config.root = ARGV.fetch(0)
        ConsoleFailureApplication.initialize!
        # Exercise pass-through without depending on Rails' version-specific
        # rendering of an unrouted request while show_exceptions is disabled.
        Rails.application.routes.draw do
          get '/ordinary', to: ->(_env) { [404, { 'content-type' => 'text/plain' }, ['ordinary fixture response']] }
        end
        direct_failure = begin
          Rails.application.eager_load!
          nil
        rescue NameError => error
          error.class.name
        end
        Rails.application.singleton_class.prepend(Module.new do
          attr_reader :console_load_attempts
          def eager_load!
            @console_load_attempts = (@console_load_attempts || 0) + 1
            super
          end
        end)
        request = lambda do |path, authorized|
          env = Rack::MockRequest.env_for("http://localhost#{path}")
          env['HTTP_AUTHORIZATION'] = 'Bearer woods-fixture-token-with-32-characters' if authorized
          status, _, body = Rails.application.call(env)
          chunks = []
          body.each { |chunk| chunks << chunk }
          body.close if body.respond_to?(:close)
          [status, chunks.join]
        end
        first = request.call('/mcp/console', true)
        # Fixing this constant does not make a partially loaded worker safe to serve.
        Object.const_set(:MissingApplicationModelBase, ActiveRecord::Base)
        second = request.call('/mcp/console', true)
        unauthorized = request.call('/mcp/console', false)
        ordinary = request.call('/ordinary', true)
        puts JSON.generate(direct_failure: direct_failure, first: first, second: second,
                           unauthorized: unauthorized.first, ordinary: ordinary,
                           attempts: Rails.application.console_load_attempts)
      RUBY
      root = File.expand_path('../..', __dir__)
      out, err, status = Open3.capture3({ 'RAILS_ENV' => 'test' }, RbConfig.ruby, '-Ilib', '-e', script, directory,
                                        chdir: root)

      expect(status).to be_success, err
      result = JSON.parse(out)
      expect(result.fetch('direct_failure')).to eq('NameError')
      expect(result.fetch('first').first).to eq(503)
      expect(result.fetch('second')).to eq(result.fetch('first'))
      expect(result.values_at('unauthorized', 'attempts')).to eq([401, 1])
      expect(result.fetch('ordinary')).to eq([404, 'ordinary fixture response'])
      expect(result.fetch('first').last).not_to include('MissingApplicationModelBase', directory)
      expect(err.scan('console.eager_load.failed').length).to eq(1)
    end
  end
end
