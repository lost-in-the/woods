# frozen_string_literal: true

require 'spec_helper'
require 'woods/watch/lifecycle'

RSpec.describe Woods::Watch::Lifecycle do
  subject(:lifecycle) { described_class.new(launcher: 'owner', attempt: 'attempt', root: Dir.pwd) }

  def accept(event, pid: 100, **fields)
    lifecycle.accept(JSON.generate(version: 1, launcher: 'owner', attempt: 'attempt', pid: pid,
                                   event: event, **fields))
  end

  def load_task
    accept('hello', pid: 200)
    accept('spawned', pid: 200, child_pid: 100)
    accept('task_loaded', woods_version: Woods::VERSION)
  end

  def backend
    load_task
    accept('identity', root: Dir.pwd, index: File.join(Dir.pwd, 'tmp/index'))
    accept('backend_ready')
  end

  it 'distinguishes backend availability from completed reconciliation' do
    backend
    expect(lifecycle.state).to eq('reconciling')
    accept('startup', state: 'ready', generation: 1, reason: 'reconciled')
    expect(lifecycle.state).to eq('ready')
  end

  it 'refuses a zero-generation successful startup' do
    backend
    expect do
      accept('startup', state: 'ready', generation: 0, reason: 'reconciled')
    end.to raise_error(ArgumentError, /startup completion/)
  end

  it 'rejects valid JSON with malformed event bodies and unknown events' do
    load_task
    expect { accept('invented') }.to raise_error(ArgumentError, /unknown/)
    expect { accept('exit', pid: 200, code: '75') }.to raise_error(ArgumentError, /guardian exit/)
  end

  it 'rejects an incompatible task handshake' do
    accept('hello', pid: 200)
    expect { accept('task_loaded', woods_version: 'not a version') }.to raise_error(ArgumentError, /task handshake/)
  end

  it 'allows the task to run before the guardian can report its spawn, with the same identity' do
    accept('hello', pid: 200)
    accept('task_loaded', woods_version: Woods::VERSION)
    accept('spawned', pid: 200, child_pid: 100)
    expect { accept('spawned', pid: 200, child_pid: 100) }.to raise_error(ArgumentError, /duplicate/)
  end

  it 'rejects messages after task termination or guardian exit' do
    load_task
    expect(lifecycle).not_to be_finished
    accept('terminal', reason: 'unsupported_environment')
    expect { accept('backend_ready') }.to raise_error(ArgumentError, /after terminal/)
    accept('exit', pid: 200, code: 0)
    expect(lifecycle).to be_finished
    expect { accept('hello', pid: 300) }.to raise_error(ArgumentError, /after guardian exit/)
  end
end
