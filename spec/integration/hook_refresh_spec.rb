# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'json'
require 'base64'
require 'open3'

# Every task gets a fresh Rails process, exactly like the shipped hook.
RSpec.describe 'Booted hook refresh', :booted_app do
  let(:root) { File.expand_path('../..', __dir__) }

  def run_rake(app, task)
    out, err, status = Open3.capture3(RbConfig.ruby, File.join(root, 'bin/rake'), task, chdir: app)
    expect(status).to be_success, "#{out}\n#{err}"
  end

  def make_app(app) # rubocop:disable Metrics/MethodLength -- complete executable Rails fixture
    FileUtils.cp_r(File.join(root, 'spec/dummy/.'), app)
    File.write(File.join(app, 'Rakefile'), <<~RUBY)
      require 'rake'
      require 'woods'
      task :environment do
        require 'rails'
        require 'active_record/railtie'
        require 'action_controller/railtie'
        require 'action_mailer/railtie'
        require 'active_job/railtie'
        require 'logger'
        require './config/application_config'
        ENV['WOODS_DUMMY_DB'] = File.join(Dir.pwd, 'dummy.sqlite3')
        class HookFixtureApplication < Rails::Application
          config.root = Dir.pwd
          config.secret_key_base = 'woods-hook-fixture'
          config.eager_load = false
          config.logger = Logger.new(IO::NULL)
        end
        WoodsDummyConfig.apply(HookFixtureApplication.config, Dir.pwd)
        HookFixtureApplication.initialize!
        ActiveRecord::Base.establish_connection(:test)
        unless ActiveRecord::Base.connection.table_exists?(:posts)
          ActiveRecord::Schema.verbose = false
          ActiveRecord::Schema.define do
            create_table(:posts) { |t| t.string :title; t.integer :status; t.timestamps }
            create_table(:comments) { |t| t.references :post; t.text :body; t.timestamps }
          end
        end
        Rails.application.eager_load!
        Woods.configuration.concurrent_extraction = false
        require 'woods/extractor'
        module HookExtractionTrace
          def extract_all(*)
            File.open(File.join(Rails.root, 'actions.log'), 'a') { |f| f.puts 'full' }
            super
          end
          def extract_changed(*)
            File.open(File.join(Rails.root, 'actions.log'), 'a') { |f| f.puts 'incremental' }
            super
          end
        end
        Woods::Extractor.prepend(HookExtractionTrace)
      end
      load #{File.join(root, 'lib/tasks/woods.rake').inspect}
    RUBY
  end

  def hook(app, path)
    env = { 'WOODS_HOOKS_ENABLED' => '1', 'WOODS_HOOK_RAKE' => "#{RbConfig.ruby} #{root}/bin/rake" }
    payload = JSON.generate(cwd: app, hook_event_name: 'PostToolUse', tool_name: 'Write',
                            tool_input: { file_path: File.join(app, path) })
    _out, err, status = Open3.capture3(env, 'bash', File.join(root, 'plugin/hooks/woods-post-edit.sh'),
                                       stdin_data: payload)
    expect(status).to be_success, err
    pending = Dir[File.join(app, 'tmp/woods/hook-pending/*.json')]
    log = File.read(File.join(app, 'tmp/woods/hook.log'))
    expect(pending).to be_empty, log
  end

  def marker(app)
    JSON.parse(File.read(File.join(app, 'tmp/woods/generation.json')))
  end

  def payload(app)
    File.join(app, 'tmp/woods', marker(app).fetch('payload'))
  end

  it 'publishes a non-model service edit from the actual hook subprocess' do
    Dir.mktmpdir('woods-hook-rails') do |app|
      make_app(app)
      run_rake(app, 'woods:extract')
      before = marker(app)
      relative = 'app/services/hook_checkout_service.rb'
      FileUtils.mkdir_p(File.dirname(File.join(app, relative)))
      File.write(File.join(app, relative), "class HookCheckoutService\n  def call; :paid; end\nend\n")
      hook(app, relative)
      expect(marker(app).fetch('number')).to be > before.fetch('number')
      units = JSON.parse(File.read(File.join(payload(app), 'services/_index.json')))
      expect(units.map { |unit| unit.fetch('identifier') }).to include('HookCheckoutService')
      expect(File.read(File.join(app, 'actions.log')).lines.map(&:strip)).to eq(%w[full incremental])
      run_rake(app, 'woods:validate')
    end
  end

  it 'removes a deleted runtime controller through explicit operation transport' do
    Dir.mktmpdir('woods-hook-rails') do |app|
      make_app(app)
      relative = 'app/controllers/hook_checkout_controller.rb'
      File.write(File.join(app, relative), "class HookCheckoutController < ApplicationController; end\n")
      run_rake(app, 'woods:extract')
      index_path = -> { File.join(payload(app), 'controllers/_index.json') }
      before = JSON.parse(File.read(index_path.call)).map { |unit| unit.fetch('identifier') }
      expect(before).to include('HookCheckoutController')
      FileUtils.rm(File.join(app, relative))
      batch = Base64.strict_encode64(JSON.generate(version: 1, output: 'tmp/woods',
                                                   events: [{ path: relative, operation: 'delete' }]))
      run_rake(app, "woods:hook_refresh[#{batch}]")
      after = JSON.parse(File.read(index_path.call)).map { |unit| unit.fetch('identifier') }
      expect(after).to eq(before - ['HookCheckoutController'])
      expect(File.read(File.join(app, 'actions.log')).lines.map(&:strip)).to eq(%w[full full])
      run_rake(app, 'woods:validate')
    end
  end

  it 'boots again and publishes a full generation for initializer changes' do
    Dir.mktmpdir('woods-hook-rails') do |app|
      make_app(app)
      run_rake(app, 'woods:extract')
      before = marker(app)
      relative = 'config/initializers/hook_middleware.rb'
      FileUtils.mkdir_p(File.dirname(File.join(app, relative)))
      File.write(File.join(app, relative), <<~RUBY)
        class HookMiddleware
          def initialize(app); @app = app; end
          def call(env); @app.call(env); end
        end
        Rails.application.config.middleware.use HookMiddleware
      RUBY
      hook(app, relative)
      expect(marker(app).fetch('number')).to be > before.fetch('number')
      artifacts = Dir[File.join(payload(app), 'middleware/*.json')].map { |path| File.read(path) }.join
      expect(artifacts).to include('HookMiddleware')
      expect(File.read(File.join(app, 'actions.log')).lines.map(&:strip)).to eq(%w[full full])
      run_rake(app, 'woods:validate')
    end
  end
end
