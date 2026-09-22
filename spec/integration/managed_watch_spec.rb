# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'open3'
require 'json'
require 'timeout'
require 'woods/mcp/index_reader'

RSpec.describe 'Managed watcher against independent Rails boots', :booted_app do
  let(:repo) { File.expand_path('../..', __dir__) }

  around do |example|
    Dir.mktmpdir('woods managed rails ') do |root|
      @root = root
      FileUtils.mkdir_p(File.join(root, 'config', 'initializers'))
      FileUtils.mkdir_p(File.join(root, 'app', 'services'))
      File.write(File.join(root, 'Rakefile'), rakefile)
      File.write(File.join(root, 'config', 'database.yml'),
                 "development:\n  adapter: sqlite3\n  database: ':memory:'\n")
      File.write(File.join(root, 'config', 'initializers', 'zone.rb'), "Rails.application.config.time_zone = 'UTC'\n")
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
                              File.join(repo, 'exe/woods-watch'), '--root', @root, '--boot-timeout', '30',
                              '--shutdown-timeout', '2', '--', *command,
                              in: File::NULL, out: @log, err: @log, pgroup: true)
  end

  def wait_until
    Timeout.timeout(45) { sleep 0.05 until yield }
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

  it 'catches up, publishes create/edit/delete to one reader, and absorbs an initializer restart' do
    launch
    wait_until { supervisor_record&.fetch('state') == 'ready' }
    reader = Woods::MCP::IndexReader.new(index)
    original_child = supervisor_record.fetch('child_pid')
    expect(reader.find_unit('CheckoutService')).to be_nil

    service = File.join(@root, 'app', 'services', 'checkout_service.rb')
    File.write(service, "class CheckoutService\n  def call; :first; end\nend\n")
    wait_until { reader.find_unit('CheckoutService') }
    File.write(service, "class CheckoutService\n  def changed; :second; end\nend\n")
    wait_until { reader.find_unit('CheckoutService').to_json.include?('changed') }
    File.unlink(service)
    wait_until { reader.find_unit('CheckoutService').nil? }

    File.write(File.join(@root, 'config', 'initializers', 'zone.rb'),
               "Rails.application.config.time_zone = 'Hawaii'\n")
    wait_until do
      record = supervisor_record
      record && record['state'] == 'ready' && record['child_pid'] && record['child_pid'] != original_child
    end
    generation = Woods::Generation.new(output_dir: index)
    expect(Dir[generation.payload_dir.join('configurations', '*.json')].any? do |path|
      JSON.parse(File.read(path)).dig('metadata', 'behavior_flags', 'time_zone') == 'Hawaii'
    end).to be true
    expect(Process.waitpid(@launcher, Process::WNOHANG)).to be_nil
    child = supervisor_record.fetch('child_pid')
    stop_launcher
    expect { Process.kill(0, child) }.to raise_error(Errno::ESRCH)
    expect(supervisor_record.fetch('state')).to eq('stopped')
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
      class ManagedWatchApplication < Rails::Application
        config.root = #{@root.inspect}
        config.eager_load = false
        config.cache_classes = false
        config.secret_key_base = 'woods-managed-watch-fixture'
        config.logger = Logger.new(IO::NULL)
        config.active_record.database_selector = nil
      end
      Rails.application = ManagedWatchApplication.instance
      task :environment do
        Rails.application.initialize!
        ActiveRecord::Base.establish_connection(adapter: 'sqlite3', database: ':memory:')
        Woods.configuration.concurrent_extraction = false
        Woods.configuration.include_framework_sources = false
      end
      load #{File.join(repo, 'lib/tasks/woods.rake').inspect}
    RUBY
  end
end
