# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'open3'
require 'json'
require 'timeout'
require 'woods/generation'

# Separate processes are essential: Rails does not rerun initializers when a
# second daemon object is constructed in an already initialized application.
RSpec.describe 'Watch startup across real Rails boots', :booted_app do
  let(:repo) { File.expand_path('../..', __dir__) }

  around do |example|
    Dir.mktmpdir('woods_watch_boot') do |root|
      @root = root
      FileUtils.mkdir_p(File.join(root, 'config', 'initializers'))
      # ConfigurationExtractor records this conventional source. Without the
      # file, every later startup correctly treats it as a deleted boot input.
      File.write(File.join(root, 'config/application.rb'), "# Application is defined in the fixture Rakefile.\n")
      File.write(File.join(root, 'Rakefile'), rakefile)
      File.write(File.join(root, 'config', 'database.yml'),
                 "development:\n  adapter: sqlite3\n  database: ':memory:'\n")
      example.run
    end
  end

  def initializer(value)
    File.write(File.join(@root, 'config', 'initializers', 'zone.rb'),
               "Rails.application.config.time_zone = #{value.inspect}\n")
  end

  def run_watch(**extra)
    env = {
      'RAILS_ENV' => 'development', 'WOODS_OUTPUT' => File.join(@root, 'tmp', 'woods'),
      'WOODS_WATCH_POLL' => '1', 'WOODS_WATCH_IDLE_TIMEOUT' => '0.15', 'WOODS_WATCH_DEBOUNCE' => '0'
    }.merge(extra.transform_keys(&:to_s))
    Open3.popen3(env, RbConfig.ruby, File.join(repo, 'bin/rake'), '--rakefile',
                 File.join(@root, 'Rakefile'), 'woods:watch', chdir: @root) do |input, output, error, child|
      input.close
      stdout = Thread.new { output.read }
      stderr = Thread.new { error.read }
      status = Timeout.timeout(30) { child.value }
      [stdout.value, stderr.value, status]
    ensure
      Process.kill('KILL', child.pid) if child&.alive?
    end
  end

  def generation
    Woods::Generation.new(output_dir: File.join(@root, 'tmp', 'woods'))
  end

  def indexed_time_zone
    Dir[generation.payload_dir.join('configurations', '*.json')].filter_map do |path|
      data = JSON.parse(File.read(path))
      data.dig('metadata', 'behavior_flags', 'time_zone') if data.is_a?(Hash)
    end.first
  end

  it 'reconciles new initializer state once and keeps the next boot current' do
    initializer('UTC')
    out, err, status = run_watch
    expect(status.exitstatus).to eq(0), "#{out}\n#{err}"
    first = generation.current.number
    expect(first).to be > 0
    expect(indexed_time_zone).to eq('UTC')

    initializer('Hawaii')
    out, err, status = run_watch
    expect(status.exitstatus).to eq(0), "#{out}\n#{err}"
    expect(generation.current.number).to eq(first + 1)
    expect(indexed_time_zone).to eq('Hawaii')

    out, err, status = run_watch
    expect(status.exitstatus).to eq(0), "#{out}\n#{err}"
    expect(generation.current.number).to eq(first + 1)
  end

  it 'exits 75 for an edit during environment initialization, then recovers on a fresh boot' do
    initializer('UTC')
    out, err, status = run_watch('EDIT_DURING_BOOT' => '1')
    expect(status.exitstatus).to eq(75), "#{out}\n#{err}"
    expect(generation.current.number).to eq(0)

    out, err, status = run_watch
    expect(status.exitstatus).to eq(0), "#{out}\n#{err}"
    expect(generation.current.number).to eq(1)
    expect(indexed_time_zone).to eq('Hawaii')
  end

  it 'keeps restart handling conservative if the environment was already invoked' do
    initializer('UTC')
    out, err, status = run_watch('EARLY_BOOT' => 'environment')

    expect(status.exitstatus).to eq(75), "#{out}\n#{err}"
    expect(generation.current.number).to eq(0)
  end

  it 'keeps restart handling conservative if Rails was already initialized' do
    initializer('UTC')
    out, err, status = run_watch('EARLY_BOOT' => 'rails')

    expect(status.exitstatus).to eq(75), "#{out}\n#{err}"
    expect(generation.current.number).to eq(0)
  end

  def rakefile
    <<~RUBY
      require 'rake'
      require 'rails'
      require 'active_record/railtie'
      require 'action_controller/railtie'
      require 'action_mailer/railtie'
      require 'active_job/railtie'
      require 'logger'
      require 'woods'

      class WatchBootApplication < Rails::Application
        config.root = #{@root.inspect}
        config.eager_load = false
        config.secret_key_base = 'woods-watch-startup-fixture'
        config.logger = Logger.new(IO::NULL)
        config.active_record.database_selector = nil
      end
      Rails.application = WatchBootApplication.instance
      task :environment do
        Rails.application.initialize! unless Rails.application.initialized?
        ActiveRecord::Base.establish_connection(adapter: 'sqlite3', database: ':memory:')
        Woods.configuration.concurrent_extraction = false
        Woods.configuration.include_framework_sources = false
        if ENV['EDIT_DURING_BOOT'] == '1'
          File.write(Rails.root.join('config/initializers/zone.rb'),
                     "Rails.application.config.time_zone = 'Hawaii'\\n")
        end
      end
      load #{File.join(repo, 'lib/tasks/woods.rake').inspect}
      Rake::Task[:environment].invoke if ENV['EARLY_BOOT'] == 'environment'
      Rails.application.initialize! if ENV['EARLY_BOOT'] == 'rails'
    RUBY
  end
end
