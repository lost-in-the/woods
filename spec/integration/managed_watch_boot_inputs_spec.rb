# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'json'
require 'timeout'
require 'woods/generation'

# F3: a loaded Rakefile, or a config/*.rb helper it requires, changing a
# config value the extraction captures. The managed watcher used to stay
# `ready` on the same child over a published value the file no longer set.
# Adapted from the independent reviewer's regression (f3-loaded-rakefile).
RSpec.describe 'Managed watcher and loaded boot inputs', :booted_app do
  let(:repo) { File.realpath(File.expand_path('../..', __dir__)) }

  around do |example|
    Dir.mktmpdir('woods managed boot ') do |root|
      @root = File.realpath(root)
      FileUtils.mkdir_p(File.join(@root, 'config', 'initializers'))
      FileUtils.mkdir_p(File.join(@root, 'app', 'services'))
      File.write(File.join(@root, 'config', 'database.yml'),
                 "development:\n  adapter: sqlite3\n  database: ':memory:'\n")
      File.write(File.join(@root, 'config', 'application.rb'), application)
      File.write(File.join(@root, 'config', 'environment.rb'),
                 "require_relative 'application'\nRails.application.initialize!\n")
      example.run
    ensure
      stop_launcher
    end
  end

  def index
    File.join(@root, 'index')
  end

  def launch
    @log = File.open(File.join(@root, 'launcher.log'), 'w')
    environment = ENV.to_h.merge('RAILS_ENV' => 'development', 'WOODS_OUTPUT' => index,
                                 'WOODS_WATCH_POLL' => '1', 'WOODS_WATCH_POLL_INTERVAL' => '0.05',
                                 'WOODS_WATCH_IDLE_TIMEOUT' => nil, 'WOODS_WATCH_DEBOUNCE' => '0.02')
    command = [RbConfig.ruby, '-rbundler/setup', File.join(repo, 'bin/rake'), '--rakefile',
               File.join(@root, 'Rakefile'), 'woods:watch']
    @launcher = Process.spawn(environment, RbConfig.ruby, '-I', File.join(repo, 'lib'),
                              File.join(repo, 'exe/woods-watch'), '--root', @root, '--boot-timeout', '60',
                              '--shutdown-timeout', '2', '--', *command,
                              in: File::NULL, out: @log, err: @log, pgroup: true)
  end

  def wait_until
    Timeout.timeout(90) { sleep 0.05 until yield }
  rescue Timeout::Error
    raise "Managed Rails fixture timed out:\n#{File.read(File.join(@root, 'launcher.log'))}"
  end

  def supervisor_record
    path = Dir[File.join(index, 'watch_supervisors', '*.json')].first
    path && JSON.parse(File.read(path))
  end

  def stop_launcher
    return unless @launcher

    Process.kill('TERM', @launcher)
    Timeout.timeout(10) { Process.wait(@launcher) }
  rescue Errno::ESRCH, Errno::ECHILD
    nil
  ensure
    @log&.close
    @launcher = nil
  end

  def published_time_zones
    generation = Woods::Generation.new(output_dir: index)
    Dir[generation.payload_dir.join('configurations', '*.json')].filter_map do |file|
      data = JSON.parse(File.read(file))
      data.dig('metadata', 'behavior_flags', 'time_zone') if data.is_a?(Hash)
    end
  end

  def ready_generation
    wait_until { supervisor_record&.fetch('state') == 'ready' }
    Woods::Generation.new(output_dir: index).current.number
  end

  def expect_restart_republishes_zone(path, from:, to:)
    launch
    before = ready_generation
    child = supervisor_record.fetch('child_pid')
    expect(published_time_zones).to include(from)

    rewrite_zone(path, from, to)

    wait_until { ready_generation > before }
    expect(supervisor_record.fetch('child_pid')).not_to eq(child)
    expect(published_time_zones).to include(to)
    expect(published_time_zones).not_to include(from)
  end

  def rewrite_zone(path, from, to)
    File.write(path, File.read(path).sub("time_zone = '#{from}'", "time_zone = '#{to}'"))
  end

  it 'restarts the child and republishes when the loaded Rakefile changes a config value (F3)' do
    File.write(File.join(@root, 'Rakefile'), rakefile_setting_zone)

    expect_restart_republishes_zone(File.join(@root, 'Rakefile'), from: 'UTC', to: 'Hawaii')
  end

  it 'restarts the child and republishes when a config helper loaded at boot changes a value (F3)' do
    File.write(File.join(@root, 'config', 'time_zone.rb'), "Rails.application.config.time_zone = 'UTC'\n")
    File.write(File.join(@root, 'Rakefile'), rakefile_requiring_helper)

    expect_restart_republishes_zone(File.join(@root, 'config', 'time_zone.rb'), from: 'UTC', to: 'Hawaii')
  end

  def application
    <<~RUBY
      require 'rails'
      require 'active_record/railtie'
      require 'action_controller/railtie'
      require 'action_mailer/railtie'
      require 'active_job/railtie'
      require 'logger'
      require 'woods'
      class ManagedBootApplication < Rails::Application
        config.root = #{@root.inspect}
        config.eager_load = false
        config.cache_classes = false
        config.secret_key_base = 'woods-managed-boot-fixture'
        config.logger = Logger.new(IO::NULL)
        config.active_record.database_selector = nil
      end
      Rails.application = ManagedBootApplication.instance
      Woods.configuration.concurrent_extraction = false
      Woods.configuration.include_framework_sources = false
    RUBY
  end

  def rakefile_setting_zone
    <<~RUBY
      require_relative 'config/application'
      Rails.application.config.time_zone = 'UTC'
      Rails.application.load_tasks
    RUBY
  end

  def rakefile_requiring_helper
    <<~RUBY
      require_relative 'config/application'
      require_relative 'config/time_zone'
      Rails.application.load_tasks
    RUBY
  end
end
