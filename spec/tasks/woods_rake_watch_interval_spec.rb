# frozen_string_literal: true

require 'spec_helper'
require 'open3'
require 'tmpdir'

RSpec.describe 'woods:watch polling interval' do
  let(:root) { File.expand_path('../..', __dir__) }

  # The subprocess must load the real task and constructor without starting a resident loop.
  # rubocop:disable-next Metrics/MethodLength
  def run_watch(interval)
    Dir.mktmpdir('woods-watch-interval') do |dir|
      rakefile = File.join(dir, 'Rakefile')
      File.write(rakefile, <<~RUBY)
        $LOAD_PATH.unshift(#{File.join(root, 'lib').inspect})
        require 'rake'
        require 'woods'
        require 'woods/watch/daemon'
        require 'logger'
        module Rails
          def self.application = self
          def self.initialized? = false
          def self.root = Pathname.new(#{dir.inspect})
          def self.logger = Logger.new($stderr)
        end
        class Woods::Watch::Daemon
          def run
            puts "interval=\#{@poll_interval}"
            :stopped
          end
        end
        task :environment
        load #{File.join(root, 'lib/tasks/woods.rake').inspect}
      RUBY
      env = { 'WOODS_WATCH_POLL_INTERVAL' => interval, 'WOODS_OUTPUT' => File.join(dir, 'index') }
      Open3.capture3(env, RbConfig.ruby, File.join(root, 'bin/rake'), '--rakefile', rakefile, 'woods:watch',
                     chdir: dir)
    end
  end

  it 'defaults to one second' do
    out, err, status = run_watch(nil)
    expect(status).to be_success, err
    expect(out).to include('interval=1.0')
  end

  it 'passes fractional seconds through the task to the daemon' do
    out, err, status = run_watch('2.5')
    expect(status).to be_success, err
    expect(out).to include('interval=2.5')
  end

  ['', 'oops', '0', '-1', 'NaN', 'Infinity', '1e999'].each do |invalid|
    it "rejects #{invalid.inspect} before running the daemon" do
      out, err, status = run_watch(invalid)
      expect(status).not_to be_success
      expect(out).not_to include('interval=')
      expect(err).to match(/poll_interval|WOODS_WATCH_POLL_INTERVAL/)
    end
  end
end
