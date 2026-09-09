# frozen_string_literal: true

require 'spec_helper'
require 'json'
require 'open3'
require 'tmpdir'
require 'fileutils'
require 'time'
require 'timeout'

# Behavior specs for the two hook scripts (#280), not the JSON they are
# wired through: hooks.json's shape is exercised indirectly here (a wiring
# typo would break every example below), and directly only for the handful
# of properties a malformed file could get wrong without any example
# noticing (matcher, async, script paths, executability, syntax).
RSpec.describe 'plugin hooks (#280)' do
  let(:plugin_root) { File.expand_path('../../plugin', __dir__) }
  let(:hooks_path) { File.join(plugin_root, 'hooks', 'hooks.json') }
  let(:post_edit) { File.join(plugin_root, 'hooks', 'woods-post-edit.sh') }
  let(:session_start) { File.join(plugin_root, 'hooks', 'woods-session-start.sh') }

  # Resolved outside any restricted PATH a test builds for itself, so the
  # interpreter is never subject to the PATH being tested.
  let(:bash_path) { `which bash`.strip }

  def run_hook(script, payload, env = {})
    Open3.capture3(env, bash_path, script, stdin_data: JSON.generate(payload))
  end

  def edit_payload(dir, relative_path)
    { 'cwd' => dir, 'tool_input' => { 'file_path' => File.join(dir, relative_path) } }
  end

  def make_app(dir, with_index: true, tmp_subdir: 'tmp/woods', updated_at: '2026-09-01T00:00:00Z')
    output_dir = File.join(dir, tmp_subdir)
    FileUtils.mkdir_p(output_dir)
    return output_dir unless with_index

    File.write(File.join(output_dir, 'generation.json'),
               JSON.generate('number' => 3, 'token' => 'abc', 'updated_at' => updated_at,
                             'payload' => 'payloads/gen-3'))
    output_dir
  end

  # A stand-in for `bundle exec rake` that records every invocation and can
  # be told to hold a run open until a control file disappears, so a spec
  # can force one hook invocation to still be running when a second fires.
  def recorder(dir)
    log = File.join(dir, 'hook_calls.log')
    started = File.join(dir, 'rake_started')
    block = File.join(dir, 'rake_block')
    script = File.join(dir, 'fake_rake.sh')
    File.write(script, <<~SH)
      #!/bin/sh
      touch "#{started}"
      while [ -f "#{block}" ]; do
        sleep 0.05
      done
      echo "$CHANGED_FILES $*" >> "#{log}"
    SH
    FileUtils.chmod(0o755, script)
    [script, log, started, block]
  end

  # A PATH containing every external command the scripts use except the
  # ones named, to exercise the mkdir-based lock fallback the way a host
  # without util-linux's `flock` would.
  def restricted_bin(dir, without:)
    bin = File.join(dir, 'restricted-bin')
    FileUtils.mkdir_p(bin)
    %w[cat mkdir rmdir sed tr git ruby date sleep jq touch].each do |tool|
      next if without.include?(tool)

      real = `which #{tool}`.strip
      next if real.empty?

      FileUtils.ln_s(real, File.join(bin, tool))
    end
    bin
  end

  def wait_until(timeout_s: 10)
    deadline = Time.now + timeout_s
    until yield
      raise "timed out waiting for condition after #{timeout_s}s" if Time.now > deadline

      sleep 0.05
    end
  end

  describe 'hooks.json' do
    it 'wires an async PostToolUse hook and a SessionStart hook to executable scripts' do
      config = JSON.parse(File.read(hooks_path))
      post = config.dig('hooks', 'PostToolUse', 0)
      start = config.dig('hooks', 'SessionStart', 0)

      expect(post['matcher']).to eq('Edit|Write|MultiEdit')
      expect(post.dig('hooks', 0)).to include('type' => 'command', 'async' => true)
      expect(post.dig('hooks', 0, 'command')).to include('${CLAUDE_PLUGIN_ROOT}/hooks/woods-post-edit.sh')
      expect(start['matcher']).to eq('startup|resume')
      expect(start.dig('hooks', 0, 'command')).to include('${CLAUDE_PLUGIN_ROOT}/hooks/woods-session-start.sh')
      expect(File.executable?(post_edit)).to be(true)
      expect(File.executable?(session_start)).to be(true)
    end

    it 'has scripts that parse' do
      [post_edit, session_start].each do |script|
        _out, err, status = Open3.capture3(bash_path, '-n', script)
        expect(status).to be_success, err
      end
    end
  end

  describe 'woods-post-edit.sh' do
    let(:base_env) { { 'WOODS_HOOKS_ENABLED' => '1' } }

    it 'does nothing when the hook has not been opted in' do
      Dir.mktmpdir('woods-hook') do |dir|
        make_app(dir)
        rake, log, = recorder(dir)

        _out, err, status = run_hook(post_edit,
                                     edit_payload(dir, 'app/models/user.rb'),
                                     'WOODS_HOOK_RAKE' => rake)

        expect(status).to be_success, err
        expect(File.exist?(log)).to be(false)
      end
    end

    it 'runs woods:incremental with CHANGED_FILES for a graph-changing path once enabled' do
      Dir.mktmpdir('woods-hook') do |dir|
        make_app(dir)
        rake, log, = recorder(dir)

        _out, err, status = run_hook(post_edit,
                                     edit_payload(dir, 'app/models/user.rb'),
                                     base_env.merge('WOODS_HOOK_RAKE' => rake))

        expect(status).to be_success, err
        expect(File.read(log)).to include('app/models/user.rb woods:incremental')
      end
    end

    it 'fires for routes, migrations, schema, and package.yml' do
      Dir.mktmpdir('woods-hook') do |dir|
        make_app(dir)
        rake, log, = recorder(dir)
        %w[config/routes.rb db/migrate/1_x.rb db/schema.rb packs/billing/package.yml].each do |path|
          run_hook(post_edit, { 'cwd' => dir, 'tool_input' => { 'file_path' => File.join(dir, path) } },
                   base_env.merge('WOODS_HOOK_RAKE' => rake))
        end

        expect(File.read(log).lines.size).to eq(4)
      end
    end

    it 'does nothing for a view path, when disabled, or without an index' do
      Dir.mktmpdir('woods-hook') do |dir|
        make_app(dir)
        rake, log, = recorder(dir)
        env = base_env.merge('WOODS_HOOK_RAKE' => rake)

        run_hook(post_edit, edit_payload(dir, 'app/views/x.html.erb'), env)
        run_hook(post_edit, edit_payload(dir, 'app/models/user.rb'),
                 env.merge('WOODS_HOOKS_DISABLED' => '1'))
        FileUtils.rm_f(File.join(dir, 'tmp/woods/generation.json'))
        run_hook(post_edit, edit_payload(dir, 'app/models/user.rb'), env)

        expect(File.exist?(log)).to be(false)
      end
    end

    it 'resolves the index directory from WOODS_OUTPUT instead of a hardcoded tmp/woods' do
      Dir.mktmpdir('woods-hook') do |dir|
        make_app(dir, tmp_subdir: 'custom_output')
        rake, log, = recorder(dir)

        _out, err, status = run_hook(post_edit,
                                     edit_payload(dir, 'app/models/user.rb'),
                                     base_env.merge('WOODS_HOOK_RAKE' => rake,
                                                    'WOODS_OUTPUT' => File.join(
                                                      dir, 'custom_output'
                                                    )))

        expect(status).to be_success, err
        expect(File.read(log)).to include('app/models/user.rb woods:incremental')
      end
    end

    shared_examples 'batches a contended edit instead of dropping it' do |extra_env|
      it 'runs the second path once the first drain finishes, without either edit blocking on the other' do
        Dir.mktmpdir('woods-hook') do |dir|
          make_app(dir)
          rake, log, started, block = recorder(dir)
          env = base_env.merge('WOODS_HOOK_RAKE' => rake).merge(extra_env)
          File.write(block, '1')

          first = Thread.new do
            run_hook(post_edit, edit_payload(dir, 'app/models/a.rb'), env)
          end

          wait_until { File.exist?(started) }

          # The first invocation is mid-run, holding the run lock. This one
          # must not wait for it: it appends its path and returns.
          out = err = status = nil
          Timeout.timeout(8) do
            out, err, status = run_hook(post_edit,
                                        edit_payload(dir, 'app/models/b.rb'), env)
          end
          expect(status).to be_success, err
          expect(out).to eq('')

          FileUtils.rm_f(block)
          first.join

          contents = File.read(log)
          expect(contents).to include('app/models/a.rb woods:incremental')
          expect(contents).to include('app/models/b.rb woods:incremental')
          expect(contents.lines.size).to eq(2)
        end
      end
    end

    context 'with flock available' do
      include_examples 'batches a contended edit instead of dropping it', {}
    end

    context 'without flock (mkdir-based lock fallback)' do
      it 'runs the second path once the first drain finishes, without either edit blocking on the other' do
        Dir.mktmpdir('woods-hook') do |dir|
          make_app(dir)
          rake, log, started, block = recorder(dir)
          bin = restricted_bin(dir, without: ['flock'])
          env = base_env.merge('WOODS_HOOK_RAKE' => rake, 'PATH' => bin)
          File.write(block, '1')

          first = Thread.new do
            run_hook(post_edit, edit_payload(dir, 'app/models/a.rb'), env)
          end

          wait_until { File.exist?(started) }

          out = err = status = nil
          Timeout.timeout(8) do
            out, err, status = run_hook(post_edit,
                                        edit_payload(dir, 'app/models/b.rb'), env)
          end
          expect(status).to be_success, err
          expect(out).to eq('')

          FileUtils.rm_f(block)
          first.join

          contents = File.read(log)
          expect(contents).to include('app/models/a.rb woods:incremental')
          expect(contents).to include('app/models/b.rb woods:incremental')
          expect(contents.lines.size).to eq(2)
        end
      end
    end
  end

  describe 'woods-session-start.sh' do
    let(:base_env) { { 'WOODS_HOOKS_ENABLED' => '1' } }

    def commit_something(dir)
      Open3.capture3(bash_path, '-c', "git init --quiet #{dir}")
      File.write(File.join(dir, 'README'), 'x')
      env = { 'GIT_AUTHOR_NAME' => 'w', 'GIT_AUTHOR_EMAIL' => 'w@x', 'GIT_COMMITTER_NAME' => 'w',
              'GIT_COMMITTER_EMAIL' => 'w@x' }
      Open3.capture3(env, 'git', '-C', dir, 'add', '.')
      Open3.capture3(env, 'git', '-C', dir, 'commit', '--quiet', '-m', 'init')
    end

    it 'does nothing when the hook has not been opted in, even when the index is stale' do
      Dir.mktmpdir('woods-hook') do |dir|
        make_app(dir)
        commit_something(dir)

        out, = run_hook(session_start, { 'cwd' => dir, 'hook_event_name' => 'SessionStart' })
        expect(out).to eq('')
      end
    end

    it 'warns when the generation predates the last commit' do
      Dir.mktmpdir('woods-hook') do |dir|
        make_app(dir)
        commit_something(dir)

        out, err, status = run_hook(session_start, { 'cwd' => dir, 'hook_event_name' => 'SessionStart' }, base_env)

        expect(status).to be_success, err
        expect(out).to include('Woods index is stale')
        expect(out).to include('woods:incremental')
      end
    end

    it 'honors WOODS_HOOKS_DISABLED even once enabled' do
      Dir.mktmpdir('woods-hook') do |dir|
        make_app(dir)
        commit_something(dir)

        out, = run_hook(session_start, { 'cwd' => dir, 'hook_event_name' => 'SessionStart' },
                        base_env.merge('WOODS_HOOKS_DISABLED' => '1'))
        expect(out).to eq('')
      end
    end

    it 'stays quiet when the generation is newer than the last commit, or when there is no index' do
      Dir.mktmpdir('woods-hook') do |dir|
        make_app(dir)
        commit_something(dir)
        File.write(File.join(dir, 'tmp/woods/generation.json'),
                   JSON.generate('number' => 4, 'token' => 'def', 'updated_at' => (Time.now.utc + 60).iso8601))

        out, = run_hook(session_start, { 'cwd' => dir, 'hook_event_name' => 'SessionStart' }, base_env)
        expect(out).to eq('')

        FileUtils.rm_f(File.join(dir, 'tmp/woods/generation.json'))
        out, = run_hook(session_start, { 'cwd' => dir, 'hook_event_name' => 'SessionStart' }, base_env)
        expect(out).to eq('')
      end
    end

    it 'resolves the index directory from WOODS_OUTPUT instead of a hardcoded tmp/woods' do
      Dir.mktmpdir('woods-hook') do |dir|
        make_app(dir, tmp_subdir: 'custom_output')
        commit_something(dir)

        out, err, status = run_hook(session_start, { 'cwd' => dir, 'hook_event_name' => 'SessionStart' },
                                    base_env.merge('WOODS_OUTPUT' => File.join(dir, 'custom_output')))

        expect(status).to be_success, err
        expect(out).to include('Woods index is stale')
      end
    end
  end
end
