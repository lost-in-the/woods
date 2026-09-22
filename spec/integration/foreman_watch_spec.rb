# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'timeout'
require 'shellwords'

RSpec.describe 'Foreman-owned watcher launcher' do
  it 'keeps the web entry alive across planned restart and stops both on owner shutdown' do
    Dir.mktmpdir('woods-foreman-') do |root|
      repo = File.expand_path('../..', __dir__)
      File.write(File.join(root, 'web.rb'), "File.write('web.pid', Process.pid); trap('TERM') { exit }; sleep\n")
      File.write(File.join(root, 'task.rb'), task_script(repo))
      watcher = [RbConfig.ruby, '-I', File.join(repo, 'lib'), File.join(repo, 'exe/woods-watch'),
                 '--root', root, '--shutdown-timeout', '1', '--', RbConfig.ruby, File.join(root, 'task.rb')]
      File.write(File.join(root, 'Procfile.dev'),
                 "web: #{Shellwords.join([RbConfig.ruby, File.join(root, 'web.rb')])}\n" \
                 "woods: #{Shellwords.join(watcher)}\n")
      log = File.open(File.join(root, 'foreman.log'), 'w') # rubocop:disable Style/FileOpen -- Closed in process cleanup.
      owner = Process.spawn(RbConfig.ruby, Gem.bin_path('foreman', 'foreman'), 'start', '-f', 'Procfile.dev',
                            chdir: root, in: File::NULL, out: log, err: log, pgroup: true)
      Timeout.timeout(15) { sleep 0.05 until File.exist?(File.join(root, 'ready')) }
      web_pid = File.read(File.join(root, 'web.pid')).to_i
      expect(Process.kill(0, web_pid)).to eq(1)
      expect(Process.waitpid(owner, Process::WNOHANG)).to be_nil
      expect(File.read(File.join(root, 'attempts')).to_i).to eq(2)
      Process.kill('TERM', owner)
      Timeout.timeout(10) { Process.wait(owner) }
      owner = nil
      expect { Process.kill(0, web_pid) }.to raise_error(Errno::ESRCH)
    ensure
      if owner
        Process.kill('KILL', -owner) rescue nil # rubocop:disable Style/RescueModifier
        Process.wait(owner) rescue nil # rubocop:disable Style/RescueModifier
      end
      log&.close
    end
  end

  def task_script(repo)
    <<~RUBY
      require #{File.join(repo, 'lib/woods/watch/managed_child').inspect}
      child = Woods::Watch::ManagedChild.from_env
      child.call(:task_loaded, woods_version: '2.0.0.beta4')
      child.call(:identity, root: Dir.pwd, index: File.join(Dir.pwd, 'index'))
      child.call(:backend_ready)
      count = File.exist?('attempts') ? File.read('attempts').to_i + 1 : 1
      File.write('attempts', count)
      if count == 1
        child.call(:terminal, reason: 'restart_required')
        exit 75
      end
      child.call(:startup, state: 'ready', generation: 1, reason: 'reconciled')
      File.write('ready', 'yes')
      trap('TERM') { exit }
      sleep
    RUBY
  end
end
