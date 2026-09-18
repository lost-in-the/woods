# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'open3'
require 'rbconfig'
require 'woods'
require 'woods/generation'

RSpec.describe 'Opt-in Claude context hook entry points' do
  let(:gem_root) { File.expand_path('../..', __dir__) }
  let(:script) { File.join(gem_root, 'plugin/hooks/woods-context.sh') }
  let(:root) { Dir.mktmpdir('woods-context-hook') }
  let(:output) { File.join(root, 'tmp/woods') }
  let(:payload) do
    { hook_event_name: 'PostToolUse', tool_name: 'Edit', session_id: 'session', cwd: root,
      tool_input: { file_path: File.join(root, 'app/models/post.rb') } }
  end
  let(:env) do
    { 'WOODS_HOOK_CONTEXT_ENABLED' => '1', 'WOODS_HOOKS_ENABLED' => '0', 'WOODS_HOOKS_DISABLED' => '0',
      'WOODS_OUTPUT' => 'tmp/woods',
      'WOODS_HOOK_CONTEXT_COMMAND' => "#{RbConfig.ruby} -I#{gem_root}/lib #{gem_root}/exe/woods-hook-context" }
  end

  before do
    FileUtils.mkdir_p(File.join(root, 'app/models'))
    File.write(File.join(root, 'app/models/post.rb'), 'class Post; end')
    publish(1)
  end
  after { FileUtils.remove_entry(root) }

  def publish(number)
    directory = File.join(output, "payloads/gen-#{number}")
    FileUtils.mkdir_p(directory)
    fixture = File.join(gem_root, 'spec/fixtures/woods')
    %w[manifest.json dependency_graph.json].each { |name| FileUtils.cp(File.join(fixture, name), directory) }
    Woods::Generation.new(output_dir: output).bump!(payload: "payloads/gen-#{number}")
  end

  def invoke(input: payload, kind: 'PostToolUse', **options)
    Open3.capture3(env.merge(options), 'bash', script, kind, stdin_data: JSON.generate(input), chdir: root)
  end

  it 'registers separate synchronous contexts while retaining asynchronous refresh' do
    hooks = JSON.parse(File.read(File.join(gem_root, 'plugin/hooks/hooks.json'))).fetch('hooks')
    %w[SessionStart PostToolUse].each do |event|
      commands = hooks.fetch(event).flat_map { |row| row.fetch('hooks') }
      context = commands.find { |hook| hook['command'].include?('woods-context.sh') }
      expect(context.fetch('command')).to end_with(event)
      expect(context['async']).not_to be(true)
    end
    expect(hooks['PostToolUse'].first['hooks'].first['async']).to be(true)
  end

  it 'emits valid additionalContext with refresh disabled, without touching an active queue or watcher' do
    FileUtils.mkdir_p(File.join(output, 'hook-pending'))
    File.write(File.join(output, 'hook-pending/event.json'), 'queued')
    File.write(File.join(output, 'watch_status.json'), '{"state":"running"}')
    stdout, stderr, status = invoke
    expect(status).to be_success
    expect(stderr).to eq('')
    data = JSON.parse(stdout).fetch('hookSpecificOutput')
    expect(data).to include('hookEventName' => 'PostToolUse')
    expect(data.fetch('additionalContext')).to include('generation 1', 'Comment (model)', 'pre-refresh')
    expect(data.fetch('additionalContext')).to include("\ndirect candidate:", '"app/models/post.rb"')
    expect(data.fetch('additionalContext')).not_to include('\\n', '\\"')
    expect(stdout.bytesize).to be <= 2048
    expect(File.read(File.join(output, 'hook-pending/event.json'))).to eq('queued')
    expect(File.read(File.join(output, 'watch_status.json'))).to eq('{"state":"running"}')
  end

  it 'does no work when context is off or global disable wins, even with refresh enabled' do
    expect(invoke('WOODS_HOOK_CONTEXT_ENABLED' => '0', 'WOODS_HOOKS_ENABLED' => '1').first).to eq('')
    expect(invoke('WOODS_HOOKS_DISABLED' => '1').first).to eq('')
    expect(File.exist?(File.join(output, 'hook-context-state.json'))).to be(false)
  end

  it 'suppresses identical events, permits repeated same-file edits and generation changes' do
    expect(invoke.first).not_to be_empty
    expect(invoke.first).to be_empty
    File.write(File.join(root, 'app/models/post.rb'), 'class Lost; end')
    expect(invoke.first).not_to be_empty
    publish(2)
    expect(invoke.first).to include('generation 2')
  end

  it 'handles missing older executables and oversized/unsupported input without a false claim' do
    expect(invoke('WOODS_HOOK_CONTEXT_COMMAND' => '/nonexistent/woods-hook-context').first).to eq('')
    expect(invoke(input: payload.merge(hook_event_name: 'PreToolUse')).first).to eq('')
    expect(invoke(input: payload.merge(extra: 'x' * 1_048_576)).first).to eq('')
  end

  it 'enforces a private deadline even when the installed command blocks before reading input' do
    blocked = File.join(root, 'blocked')
    File.write(blocked, "#!/usr/bin/env bash\nexec sleep 10\n")
    File.chmod(0o755, blocked)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    stdout, _stderr, status = invoke('WOODS_HOOK_CONTEXT_COMMAND' => blocked)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    expect(status).to be_success
    expect(stdout).to eq('')
    # The worker is killed at850ms; allow scheduler/exec bookkeeping jitter.
    expect(elapsed).to be < 1.25
    expect(File.exist?(File.join(output, 'hook-context-state.json'))).to be(false)
  end

  it 'emits a bounded orientation on the real SessionStart entry point' do
    stdout, = invoke(input: payload.merge(hook_event_name: 'SessionStart'), kind: 'SessionStart')
    expect(JSON.parse(stdout).dig('hookSpecificOutput', 'additionalContext')).to include('generation 1', 'woods_status')
  end

  it 'maps an explicit container root while preserving the changed relative path' do
    input = payload.merge(cwd: '/unmounted/host/app',
                          tool_input: { file_path: '/unmounted/host/app/app/models/post.rb' })
    stdout, = invoke('WOODS_HOOK_CONTEXT_ROOT' => root, input: input)
    expect(JSON.parse(stdout).dig('hookSpecificOutput', 'additionalContext')).to include('Comment (model)')
    expect(stdout).not_to include('/unmounted/host')
  end

  it 'keeps concurrent identical events from injecting duplicate context' do
    responses = 3.times.map { Thread.new { invoke.first } }.map(&:value)
    expect(responses.count { |response| !response.empty? }).to eq(1)
  end

  it 'does not boot Rails or call providers to produce a hint' do
    guard = File.join(root, 'guard.rb')
    File.write(guard, <<~RUBY)
      require 'net/http'
      class Net::HTTP
        def request(*)
          raise 'Provider call forbidden'
        end
      end
      module Kernel
        alias woods_context_original_require require
        def require(path)
          raise 'Rails boot forbidden' if path.to_s.match?(%r{rails/application|config/environment})
          woods_context_original_require(path)
        end
      end
    RUBY
    stdout, = invoke('RUBYOPT' => "-r#{guard}")
    expect(JSON.parse(stdout).dig('hookSpecificOutput', 'additionalContext')).to include('Comment (model)')
  end
end
