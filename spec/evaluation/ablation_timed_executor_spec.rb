# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'woods/evaluation/ablation_executor'
require 'woods/evaluation/ablation_timed_executor'

# Wraps any executor with a per-call timeout and, when the wrapped executor
# exposes a #pid, terminates the process on timeout (#280 review): a
# Timeout.timeout around Open3.capture3 interrupts the *caller*, not the
# child, so a naive implementation leaks a running process. No agent is
# invoked here, only `ruby -e 'sleep ...'`.
RSpec.describe Woods::Evaluation::AblationTimedExecutor do
  describe 'with a real subprocess (AblationExecutor)' do
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
end
