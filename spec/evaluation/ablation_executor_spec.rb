# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'woods/evaluation/ablation_executor'

# The real subprocess executor AblationRunner uses by default. No agent is
# invoked here, only plain shell commands, so this stays within "the harness
# never invokes a real agent in specs" (#280).
RSpec.describe Woods::Evaluation::AblationExecutor do
  it 'runs a command in the given directory and captures stdout, stderr, and success' do
    Dir.mktmpdir do |dir|
      executor = described_class.new

      stdout, stderr, success = executor.call('pwd', chdir: dir)

      expect(stdout.strip).to eq(File.realpath(dir))
      expect(stderr).to eq('')
      expect(success).to be(true)
    end
  end

  it 'reports failure and stderr for a nonzero exit' do
    executor = described_class.new

    _stdout, stderr, success = executor.call('echo boom 1>&2; exit 1', chdir: Dir.pwd)

    expect(stderr.strip).to eq('boom')
    expect(success).to be(false)
  end

  it 'exposes the pid of the most recently spawned process' do
    executor = described_class.new

    executor.call('true', chdir: Dir.pwd)

    expect(executor.pid).to be_a(Integer)
  end
end
