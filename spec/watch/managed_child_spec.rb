# frozen_string_literal: true

require 'spec_helper'
require 'io/wait'
require 'woods/watch/managed_child'

RSpec.describe Woods::Watch::ManagedChild do
  let(:pipe) { IO.pipe }
  let(:env) do
    { 'WOODS_WATCH_EVENT_FD' => pipe.last.fileno.to_s,
      'WOODS_WATCH_LAUNCHER_TOKEN' => 'launcher-token', 'WOODS_WATCH_ATTEMPT_TOKEN' => 'attempt-token' }
  end

  after do
    @reporter&.close
    pipe.first.close unless pipe.first.closed?
    pipe.last.close unless @reporter || pipe.last.closed?
  end

  def build_reporter
    # Transfer this test's descriptor ownership exactly once. Leaving two
    # autoclosing Ruby IO objects makes a later GC close a reused descriptor.
    @reporter = described_class.from_env(env: env)
    pipe.last.autoclose = false
    @reporter
  end

  it 'does nothing for a raw task, including its supported idle configuration' do
    expect(described_class.from_env(env: { 'WOODS_WATCH_IDLE_TIMEOUT' => '1' })).to be_nil
  end

  it 'rejects partial protocol configuration without treating it as a raw task' do
    expect do
      described_class.from_env(env: { 'WOODS_WATCH_LAUNCHER_TOKEN' => 'token' })
    end.to raise_error(ArgumentError, /managed-child environment/)
  end

  %w[0 30 invalid].each do |idle|
    it "rejects configured managed idle TTL #{idle.inspect}" do
      expect do
        described_class.from_env(env: env.merge('WOODS_WATCH_IDLE_TIMEOUT' => idle))
      end.to raise_error(ArgumentError, /must be unset/)
    end
  end

  it 'correlates messages and prevents descriptor inheritance into application subprocesses' do
    reporter = build_reporter
    reporter.call(:startup, state: 'ready', generation: 4, reason: 'reconciled')

    expect(JSON.parse(pipe.first.gets)).to eq(
      'version' => 1, 'launcher' => 'launcher-token', 'attempt' => 'attempt-token',
      'event' => 'startup', 'pid' => Process.pid, 'state' => 'ready', 'generation' => 4, 'reason' => 'reconciled'
    )
    expect(pipe.last).to be_close_on_exec
  end

  it 'writes valid independent lines when backend and main threads report concurrently' do
    reporter = build_reporter
    messages = Thread.new { Array.new(20) { JSON.parse(pipe.first.gets) } }
    writers = Array.new(4) { Thread.new { 5.times { reporter.call(:backend_ready) } } }
    writers.each(&:join)

    expect(messages.value.map { |message| message['event'] }).to eq(['backend_ready'] * 20)
  end

  it 'rejects application exception text in place of a bounded reason' do
    reporter = build_reporter

    expect do
      reporter.call(:startup, state: 'degraded', generation: 0, reason: 'secret from application exception')
    end.to raise_error(ArgumentError, /startup state or reason/)
    expect(pipe.first.wait_readable(0)).to be_nil
  end

  it 'rejects unknown events and extra fields' do
    reporter = build_reporter

    expect { reporter.call(:secret, value: 'private') }.to raise_error(ArgumentError, /event fields/)
    expect { reporter.call(:backend_ready, exception: 'private') }.to raise_error(ArgumentError, /event fields/)
  end

  it 'bounds serialized messages before touching the descriptor' do
    reporter = build_reporter

    expect do
      reporter.call(:identity, root: "/#{'a' * 5000}", index: '/index')
    end.to raise_error(ArgumentError, /size limit/)
    expect(pipe.first.wait_readable(0)).to be_nil
  end

  it 'closes its descriptor idempotently' do
    reporter = build_reporter
    reporter.close
    reporter.close

    expect(pipe.first.read).to eq('')
  end
end
