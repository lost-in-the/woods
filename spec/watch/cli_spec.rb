# frozen_string_literal: true

require 'spec_helper'
require 'woods/watch/cli'
require 'stringio'

RSpec.describe Woods::Watch::CLI do
  let(:output) { StringIO.new }
  let(:cli) { described_class.new(output: output) }

  it 'prints help without booting an application' do
    expect(Woods::Watch::Supervisor).not_to receive(:new)
    expect(cli.run(['--help'])).to eq(0)
    expect(output.string).to include('--boot-timeout', '--root', '--', 'bin/rails woods:watch')
  end

  ['0', '-1', 'NaN', 'Infinity', 'oops'].each do |value|
    it "rejects invalid boot timeout #{value}" do
      expect(cli.run(['--boot-timeout', value])).to eq(2)
      expect(output.string).to include('positive finite')
    end
  end

  it 'fails immediately on an impossible executable' do
    expect(cli.run(['--', '/woods-not-a-real-command'])).to eq(2)
    expect(output.string).to include('executable')
  end

  it 'gives an explicit external-supervisor fallback when fork is unavailable' do
    allow(Process).to receive(:respond_to?).with(:fork).and_return(false)
    expect(cli.run(['--', Gem.ruby])).to eq(2)
    expect(output.string).to include('POSIX', 'external raw-task supervisor')
  end

  it 'passes explicit arguments without a shell and restores signal handlers' do
    supervisor = instance_double(Woods::Watch::Supervisor, run: 0)
    previous = Signal.trap('TERM', 'IGNORE')
    expect(Woods::Watch::Supervisor).to receive(:new).with(
      command: [Gem.ruby, '-e', 'puts "a ; b"'], root: Dir.pwd,
      logger: output, boot_timeout: 300, shutdown_timeout: 10
    ).and_return(supervisor)
    expect(cli.run(['--', Gem.ruby, '-e', 'puts "a ; b"'])).to eq(0)
    expect(Signal.trap('TERM', 'IGNORE')).to eq('IGNORE')
  ensure
    Signal.trap('TERM', previous)
  end
end
