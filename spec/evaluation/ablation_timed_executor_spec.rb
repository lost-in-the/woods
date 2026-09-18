# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'shellwords'
require 'rbconfig'
require 'woods/evaluation/ablation_executor'
require 'woods/evaluation/ablation_timed_executor'

# Wraps any executor with a per-call timeout and, when the wrapped executor
# exposes a #pid, terminates the process on timeout (#280 review): a
# Timeout.timeout around Open3.capture3 interrupts the *caller*, not the
# child, so a naive implementation leaks a running process. No agent is
# invoked here, only `ruby -e 'sleep ...'`.
RSpec.describe Woods::Evaluation::AblationTimedExecutor do
  describe 'with a real subprocess (AblationExecutor)' do
    [false, true].each do |parent_exits|
      it "stops TERM-resistant descendants when the parent #{parent_exits ? 'already exited' : 'is waiting'}" do
        Dir.mktmpdir('woods-ablation-descendant') do |dir|
          child_script = File.join(dir, 'child.rb')
          parent_script = File.join(dir, 'parent.rb')
          heartbeat = File.join(dir, 'heartbeat')
          pid_path = File.join(dir, 'child.pid')
          File.write(child_script, <<~RUBY)
            trap('TERM') {}
            loop do
              File.write(#{heartbeat.inspect}, Process.clock_gettime(Process::CLOCK_MONOTONIC).to_s)
              sleep 0.01
            end
          RUBY
          File.write(parent_script, <<~RUBY)
            require 'rbconfig'
            child = Process.spawn(RbConfig.ruby, #{child_script.inspect})
            File.write(#{pid_path.inspect}, child.to_s)
            Process.wait(child) unless #{parent_exits}
          RUBY
          executor = Woods::Evaluation::AblationExecutor.new
          timed = described_class.new(executor, timeout: 0.5)
          _, error, success = timed.call([RbConfig.ruby, parent_script].shelljoin, chdir: dir)
          expect(success).to be(false)
          expect(error).to include('timed out')
          expect(File).to exist(heartbeat)
          sleep 0.1 # allow delivery of the final KILL before capturing the last write
          last_write = File.read(heartbeat)
          sleep 0.2
          expect(File.read(heartbeat)).to eq(last_write)
        ensure
          if pid_path && File.file?(pid_path)
            begin
              Process.kill('KILL', Integer(File.read(pid_path)))
            rescue Errno::ESRCH
              nil
            end
          end
        end
      end
    end

    it 'kills a command that outlives the timeout and dies to TERM, and reports it as a timed-out failure' do
      executor = Woods::Evaluation::AblationExecutor.new
      timed = described_class.new(executor, timeout: 0.2)

      stdout, stderr, success = timed.call("ruby -e 'sleep 30'", chdir: Dir.pwd)
      pid = executor.pid

      expect(success).to be(false)
      expect(stderr).to include('timed out')
      expect(stdout).to eq('')
      expect(pid).to be_a(Integer)
      expect { Process.kill(0, pid) }.to raise_error(Errno::ESRCH)
    end

    # `sleep` terminates on the first TERM, so the test above never reaches
    # the KILL fallback. A child that traps and swallows TERM does (#280
    # re-review).
    it 'falls back to KILL when the process traps and ignores TERM, and still reports a timed-out failure' do
      executor = Woods::Evaluation::AblationExecutor.new
      timed = described_class.new(executor, timeout: 0.2)

      stdout, stderr, success = timed.call(%(ruby -e 'trap("TERM"){}; sleep 30'), chdir: Dir.pwd)
      pid = executor.pid

      expect(success).to be(false)
      expect(stderr).to include('timed out')
      expect(stdout).to eq('')
      expect(pid).to be_a(Integer)
      expect { Process.kill(0, pid) }.to raise_error(Errno::ESRCH)
    end

    it 'passes through a command that finishes inside the timeout' do
      executor = Woods::Evaluation::AblationExecutor.new
      timed = described_class.new(executor, timeout: 5)

      stdout, _stderr, success = timed.call('echo ok', chdir: Dir.pwd)

      expect(stdout.strip).to eq('ok')
      expect(success).to be(true)
    end

    it 'does not falsely report a timeout when the child writes more than a pipe buffer to both streams' do
      Dir.mktmpdir do |dir|
        script = File.join(dir, 'big_output.rb')
        File.write(script, <<~RUBY)
          $stdout.write('o' * 200_000)
          $stderr.write('e' * 200_000)
        RUBY
        executor = Woods::Evaluation::AblationExecutor.new
        timed = described_class.new(executor, timeout: 5)

        stdout, stderr, success = timed.call("ruby #{script}", chdir: dir)

        expect(success).to be(true)
        expect(stdout.bytesize).to eq(200_000)
        expect(stderr.bytesize).to eq(200_000)
      end
    end
  end

  describe 'with an executor that does not expose a pid' do
    it 'still reports the timeout, without attempting to kill anything' do
      slow = lambda do |_command, chdir:|
        sleep 0.2
        ["late in #{chdir}", '', true]
      end
      timed = described_class.new(slow, timeout: 0.01)

      stdout, stderr, success = timed.call('whatever', chdir: Dir.pwd)

      expect(success).to be(false)
      expect(stderr).to include('timed out after 0.01s')
      expect(stdout).to eq('')
    end
  end

  it 'terminates only the PID supplied by a custom executor without a group' do
    pid = Process.spawn(RbConfig.ruby, '-e', 'sleep 30')
    custom = Struct.new(:pid) do
      def call(*)
        sleep 30
      end
    end.new(pid)
    timed = described_class.new(custom, timeout: 0.01)

    expect(timed.call('custom', chdir: Dir.pwd).last).to be(false)
    expect { Process.kill(0, pid) }.to raise_error(Errno::ESRCH)
  ensure
    begin
      Process.kill('KILL', pid) if pid
      Process.wait(pid) if pid
    rescue Errno::ESRCH, Errno::ECHILD
      nil
    end
  end
end
