# frozen_string_literal: true

require 'spec_helper'
require 'json'
require 'base64'
require 'open3'
require 'tmpdir'
require 'fileutils'
require 'time'
require 'timeout'
require 'shellwords'

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
    payload = { 'hook_event_name' => 'PostToolUse', 'tool_name' => 'Write' }.merge(payload) if script == post_edit
    Open3.capture3(env, bash_path, script, stdin_data: JSON.generate(payload))
  end

  def edit_payload(dir, relative_path)
    { 'cwd' => dir, 'hook_event_name' => 'PostToolUse', 'tool_name' => 'Write',
      'tool_input' => { 'file_path' => File.join(dir, relative_path) } }
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
      #{RbConfig.ruby} -rjson -rbase64 -e '
        batch = JSON.parse(Base64.strict_decode64(ARGV.fetch(0).split("[", 2).last.delete_suffix("]")))
        task = batch.fetch("events").any? { |event| event.fetch("path") == "db/schema.rb" } ? "woods:extract" : "woods:incremental"
        puts "\#{batch.fetch("events").map { |event| event.fetch("path") }.join(",")} \#{task}"
      ' "$1" >> "#{log}"
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
    %w[cat head tail mktemp mkdir rmdir sed tr git ruby date sleep jq touch stat mv rm wc].each do |tool|
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
      [post_edit, session_start, File.join(plugin_root, 'hooks', 'woods-refresh.sh')].each do |script|
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

    it 'does nothing for unrelated documentation, when disabled, or without an index' do
      Dir.mktmpdir('woods-hook') do |dir|
        make_app(dir)
        rake, log, = recorder(dir)
        env = base_env.merge('WOODS_HOOK_RAKE' => rake)

        run_hook(post_edit, edit_payload(dir, 'docs/example.md'), env)
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

    it 'refreshes the supported non-model inputs and keeps unrelated paths quiet' do
      Dir.mktmpdir('woods-hook') do |dir|
        make_app(dir)
        rake, log, = recorder(dir)
        paths = %w[app/services/pay.rb app/controllers/pay_controller.rb app/jobs/pay_job.rb
                   app/views/pay/index.html.erb app/models/concerns/payable.rb config/locales/en.yml
                   spec/models/pay_spec.rb test/models/pay_test.rb lib/pay.rb]
        paths.each { |path| run_hook(post_edit, edit_payload(dir, path), base_env.merge('WOODS_HOOK_RAKE' => rake)) }
        expect(File.read(log).lines.size).to eq(paths.size)
      end
    end

    it 'uses JSON transport without a host Ruby or bundle and preserves unusual paths' do
      Dir.mktmpdir('woods-hook') do |dir|
        make_app(dir)
        rake, log, = recorder(dir)
        bin = restricted_bin(dir, without: %w[ruby flock])
        path = "app/views/a,b c\n.html.erb"
        _out, err, status = run_hook(post_edit, edit_payload(dir, path),
                                     base_env.merge('WOODS_HOOK_RAKE' => rake, 'PATH' => bin))
        expect(status).to be_success, err
        expect(File.read(log)).to include(path)
        expect(Dir[File.join(dir, 'tmp/woods/hook-pending/*.json')]).to be_empty
      end
    end

    it 'falls back to host Ruby for JSON when jq is absent' do
      Dir.mktmpdir('woods-hook') do |dir|
        make_app(dir)
        rake, log, = recorder(dir)
        bin = restricted_bin(dir, without: %w[jq flock])
        _out, err, status = run_hook(post_edit, edit_payload(dir, 'app/services/pay.rb'),
                                     base_env.merge('WOODS_HOOK_RAKE' => rake, 'PATH' => bin))
        expect(status).to be_success, err
        expect(File.read(log)).to include('app/services/pay.rb')
      end
    end

    it 'passes an encoded task argument through a Docker prefix with no forwarded environment' do
      Dir.mktmpdir('woods-hook') do |dir|
        make_app(dir)
        rake, log, = recorder(dir)
        docker = File.join(dir, 'docker')
        File.write(docker, <<~SH)
          #!/bin/sh
          [ "$1 $2 $3 $4 $5 $6 $7" = 'compose exec -T app bundle exec rake' ] || exit 9
          shift 7
          exec env -i PATH="$PATH" #{rake} "$@"
        SH
        FileUtils.chmod(0o755, docker)
        env = base_env.merge('WOODS_HOOK_RAKE' => "#{docker} compose exec -T app bundle exec rake")
        _out, err, status = run_hook(post_edit, edit_payload(dir, 'app/services/pay.rb'), env)
        expect(status).to be_success, err
        expect(File.read(log)).to include('app/services/pay.rb')
      end
    end

    [1, 75].each do |exit_status|
      it "retains a failed/deferred batch (#{exit_status}) and retries it on the next edit" do
        Dir.mktmpdir('woods-hook') do |dir|
          tmp_dir = make_app(dir)
          rake, log, = recorder(dir)
          original = File.read(rake)
          File.write(rake, "#!/bin/sh\nexit #{exit_status}\n")
          env = base_env.merge('WOODS_HOOK_RAKE' => rake)
          run_hook(post_edit, edit_payload(dir, 'app/services/first.rb'), env)
          expect(Dir[File.join(tmp_dir, 'hook-pending/*.json')].size).to eq(1)
          expect(File.read(File.join(tmp_dir, 'hook.log'))).to include("status #{exit_status}", 'retained')
          File.write(rake, original)
          run_hook(post_edit, edit_payload(dir, 'app/services/second.rb'), env)
          expect(File.read(log)).to include('app/services/first.rb', 'app/services/second.rb')
          expect(Dir[File.join(tmp_dir, 'hook-pending/*.json')]).to be_empty
        end
      end
    end

    it 'bounds a stalled command itself and retains its batch for recovery' do
      Dir.mktmpdir('woods-hook') do |dir|
        tmp_dir = make_app(dir)
        rake, _log, _started, block = recorder(dir)
        File.write(block, '1')
        Timeout.timeout(5) do
          run_hook(post_edit, edit_payload(dir, 'app/services/pay.rb'),
                   base_env.merge('WOODS_HOOK_RAKE' => rake, 'WOODS_HOOK_TIMEOUT_SECONDS' => '1'))
        end
        expect(Dir[File.join(tmp_dir, 'hook-pending/*.json')].size).to eq(1)
        expect(File.read(File.join(tmp_dir, 'hook.log'))).to include('retained')
      end
    end

    it 'imports the old pending text queue without losing its deferred edit' do
      Dir.mktmpdir('woods-hook') do |dir|
        tmp_dir = make_app(dir)
        File.write(File.join(tmp_dir, 'hook-pending.txt'), "app/models/old.rb\n")
        rake, log, = recorder(dir)
        run_hook(post_edit, edit_payload(dir, 'app/services/new.rb'), base_env.merge('WOODS_HOOK_RAKE' => rake))
        expect(File.read(log)).to include('app/models/old.rb', 'app/services/new.rb')
        expect(File.exist?(File.join(tmp_dir, 'hook-pending.txt'))).to be(false)
      end
    end

    it 'lets concurrent mkdir reclaimers recover every event after a dead owner' do
      Dir.mktmpdir('woods-hook') do |dir|
        tmp_dir = make_app(dir)
        lock = File.join(tmp_dir, 'hook.lock.d')
        FileUtils.mkdir_p(lock)
        File.write(File.join(lock, 'owner-999999999'), '')
        rake, log, = recorder(dir)
        bin = restricted_bin(dir, without: ['flock'])
        env = base_env.merge('WOODS_HOOK_RAKE' => rake, 'PATH' => bin)
        threads = 8.times.map do |i|
          Thread.new { run_hook(post_edit, edit_payload(dir, "app/services/pay_#{i}.rb"), env) }
        end
        threads.each(&:join)
        8.times { |i| expect(File.read(log)).to include("app/services/pay_#{i}.rb") }
        expect(Dir[File.join(tmp_dir, 'hook-pending/*.json')]).to be_empty
      end
    end

    it 'defers when another reclaimer replaced the directory before stale-owner removal' do
      Dir.mktmpdir('woods-hook') do |dir|
        tmp_dir = make_app(dir)
        lock = File.join(tmp_dir, 'hook.lock.d')
        owner = File.join(lock, 'owner-999999999')
        FileUtils.mkdir_p(lock)
        File.write(owner, '')
        rake, log, = recorder(dir)
        bin = restricted_bin(dir, without: %w[flock rm])
        real_rm = `which rm`.strip
        replacement_rm = File.join(bin, 'rm')
        # Schedule the other reclaimer between our owner snapshot and removal.
        # Its replacement directory has not published its owner marker yet.
        File.write(replacement_rm, <<~SH)
          #!/bin/sh
          for argument do
            if [ "$argument" = #{owner.shellescape} ]; then
              #{real_rm.shellescape} -f #{owner.shellescape}
              rmdir #{lock.shellescape} || exit 9
              mkdir #{lock.shellescape} || exit 9
              exec #{real_rm.shellescape} "$@"
            fi
          done
          exec #{real_rm.shellescape} "$@"
        SH
        FileUtils.chmod(0o755, replacement_rm)
        env = base_env.merge('WOODS_HOOK_RAKE' => rake, 'PATH' => bin)

        _out, err, status = run_hook(post_edit, edit_payload(dir, 'app/services/first.rb'), env)

        expect(status).to be_success, err
        expect(File).not_to exist(log)
        expect(Dir).to exist(lock)
        expect(Dir[File.join(tmp_dir, 'hook-pending/*.json')].size).to eq(1)

        # Once the successor publishes its owner and exits, a later edit recovers
        # both events through the ordinary dead-owner path.
        FileUtils.rm(replacement_rm)
        FileUtils.ln_s(real_rm, replacement_rm)
        File.write(owner, '')
        run_hook(post_edit, edit_payload(dir, 'app/services/second.rb'), env)
        expect(File.read(log)).to include('app/services/first.rb', 'app/services/second.rb')
        expect(Dir[File.join(tmp_dir, 'hook-pending/*.json')]).to be_empty
      end
    end

    it 'rejects foreign and traversal paths and malformed input without invoking rake' do
      Dir.mktmpdir('woods-hook') do |dir|
        make_app(dir)
        rake, log, = recorder(dir)
        env = base_env.merge('WOODS_HOOK_RAKE' => rake)
        ['/another/app/services/pay.rb', 'app/services/../../../outside.rb'].each do |path|
          run_hook(post_edit, { cwd: dir, tool_input: { file_path: path } }, env)
        end
        run_hook(post_edit, { cwd: dir, tool_input: { file_path: 123 } }, env)
        expect(File.exist?(log)).to be(false)
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

      # A directory-based lock has no kernel-enforced release, unlike flock:
      # a hook killed mid-drain leaves `hook.lock.d` or `hook-pending.lock.d`
      # behind forever. Every later hook must reclaim a lock directory once
      # it is old enough to be certain the crash already happened, and must
      # still respect one that is merely in active, legitimate use.
      context 'stale mkdir lock recovery (crash mid-drain)' do
        def backdate(path, seconds_ago:)
          FileUtils.mkdir_p(path)
          stale_time = Time.now - seconds_ago
          File.utime(stale_time, stale_time, path)
        end

        it 'reclaims a stale run lock directory left by a crashed drain' do
          Dir.mktmpdir('woods-hook') do |dir|
            tmp_dir = make_app(dir)
            rake, log, = recorder(dir)
            bin = restricted_bin(dir, without: ['flock'])
            env = base_env.merge('WOODS_HOOK_RAKE' => rake, 'PATH' => bin)
            backdate(File.join(tmp_dir, 'hook.lock.d'), seconds_ago: 3600)

            _out, err, status = run_hook(post_edit, edit_payload(dir, 'app/models/user.rb'), env)

            expect(status).to be_success, err
            expect(File.read(log)).to include('app/models/user.rb woods:incremental')
          end
        end

        it 'reclaims a stale pending lock directory instead of spinning until the hook timeout' do
          Dir.mktmpdir('woods-hook') do |dir|
            tmp_dir = make_app(dir)
            rake, log, = recorder(dir)
            bin = restricted_bin(dir, without: ['flock'])
            env = base_env.merge('WOODS_HOOK_RAKE' => rake, 'PATH' => bin)
            backdate(File.join(tmp_dir, 'hook-pending.lock.d'), seconds_ago: 3600)

            err = status = nil
            Timeout.timeout(5) do
              _out, err, status = run_hook(post_edit, edit_payload(dir, 'app/models/user.rb'), env)
            end

            expect(status).to be_success, err
            expect(File.read(log)).to include('app/models/user.rb woods:incremental')
          end
        end

        it 'still respects a fresh run lock directory instead of reclaiming it' do
          Dir.mktmpdir('woods-hook') do |dir|
            tmp_dir = make_app(dir)
            rake, log, = recorder(dir)
            bin = restricted_bin(dir, without: ['flock'])
            env = base_env.merge('WOODS_HOOK_RAKE' => rake, 'PATH' => bin)
            FileUtils.mkdir_p(File.join(tmp_dir, 'hook.lock.d')) # fresh mtime

            _out, err, status = run_hook(post_edit, edit_payload(dir, 'app/models/user.rb'), env)

            expect(status).to be_success, err
            expect(File.exist?(log)).to be(false)
            expect(Dir[File.join(tmp_dir, 'hook-pending/*.json')].map do |path|
              File.read(path)
            end.join).to include('app/models/user.rb')
          end
        end
      end
    end
  end

  describe 'woods-session-start.sh' do
    let(:base_env) { { 'WOODS_HOOKS_ENABLED' => '1' } }

    def status_command(dir, state: 'current', exit_code: 0, **evidence)
      script = File.join(dir, 'source-status.sh')
      File.write(script, <<~SH)
        #!/bin/sh
        printf '%s' "$1" > "#{dir}/status-argument"
        printf '%s\\n' '#{JSON.generate(state: state, **evidence)}'
        exit #{exit_code}
      SH
      FileUtils.chmod(0o755, script)
      base_env.merge('WOODS_HOOK_RAKE' => script)
    end

    it 'does nothing until enabled and honors the disable override' do
      Dir.mktmpdir('woods-hook') do |dir|
        make_app(dir)
        env = status_command(dir, state: 'drifted')
        [env.merge('WOODS_HOOKS_ENABLED' => '0'), env.merge('WOODS_HOOKS_DISABLED' => '1')].each do |disabled|
          out, = run_hook(session_start, { 'cwd' => dir }, disabled)
          expect(out).to eq('')
          expect(File.exist?(File.join(dir, 'status-argument'))).to be(false)
        end
      end
    end

    it 'warns on content drift without relying on commit timestamps or a git checkout' do
      Dir.mktmpdir('woods-hook') do |dir|
        make_app(dir, updated_at: (Time.now.utc + 60).iso8601)
        out, err, status = run_hook(session_start, { 'cwd' => dir }, status_command(dir, state: 'drifted'))
        expect(status).to be_success, err
        expect(out).to include('source freshness is drifted', 'woods-extract full')
      end
    end

    it 'reports missing or failed verification as unknown rather than claiming current' do
      Dir.mktmpdir('woods-hook') do |dir|
        make_app(dir)
        [status_command(dir, state: 'unknown'), status_command(dir, exit_code: 1)].each do |env|
          out, err, status = run_hook(session_start, { 'cwd' => dir }, env)
          expect(status).to be_success, err
          expect(out).to include('source freshness is unknown')
        end
      end
    end

    [true, false].each do |with_jq|
      it "uses reason-specific freshness advice with #{with_jq ? 'jq' : 'Ruby only under C locale'}" do
        Dir.mktmpdir('woods-hook-advice') do |dir|
          make_app(dir)
          environment = if with_jq
                          {}
                        else
                          { 'PATH' => restricted_bin(dir, without: ['jq']), 'LC_ALL' => 'C', 'LANG' => 'C' }
                        end
          env = status_command(dir, state: 'unknown', recommendations: ['deep_check']).merge(environment)
          out, err, status = run_hook(session_start, { 'cwd' => dir }, env)
          expect(status).to be_success, err
          expect(out).to include('source freshness is unknown', 'source_check: deep')
          expect(out).to include('this check could not verify the current source contents')
          expect(out).not_to include('woods-extract full')

          env = status_command(dir, state: 'unknown', recommendations: %w[deep_check fresh_capture inspect_source_scan])
                .merge(environment)
          out, = run_hook(session_start, { 'cwd' => dir }, env)
          expect(out).to include('source_check: deep', 'woods-extract full', 'permissions', 'source mapping')

          [nil, 'deep_check', ['unrecognized']].each do |malformed|
            env = status_command(dir, state: 'unknown', recommendations: malformed).merge(environment)
            out, = run_hook(session_start, { 'cwd' => dir }, env)
            expect(out).to include('source freshness is unknown', 'woods-extract full')
            expect(out).not_to include('source_check: deep')
          end
        end
      end
    end

    it 'reports oversized evidence as unavailable without recommending a fruitless full capture' do
      Dir.mktmpdir('woods-hook-unavailable') do |dir|
        make_app(dir)
        out, err, status = run_hook(session_start, { 'cwd' => dir }, status_command(dir, state: 'unavailable'))
        expect(status).to be_success, err
        expect(out).to include('freshness is unavailable', 'source_manifest_too_large', 'size and limit')
        expect(out).not_to include('woods-extract full', 'freshness is current')
      end
    end

    it 'stays quiet for verified current source or no existing index' do
      Dir.mktmpdir('woods-hook') do |dir|
        make_app(dir)
        env = status_command(dir)
        out, = run_hook(session_start, { 'cwd' => dir }, env)
        expect(out).to eq('')
        FileUtils.rm_f(File.join(dir, 'status-argument'))
        FileUtils.rm_f(File.join(dir, 'tmp/woods/generation.json'))
        out, = run_hook(session_start, { 'cwd' => dir }, env)
        expect(out).to eq('')
        expect(File.exist?(File.join(dir, 'status-argument'))).to be(false)
      end
    end

    it 'transports custom output and quick mode through the Docker-compatible task argument' do
      Dir.mktmpdir('woods-hook') do |dir|
        output = "custom,a b\nc"
        make_app(dir, tmp_subdir: output)
        env = status_command(dir, state: 'drifted').merge('WOODS_OUTPUT' => output)
        out, err, status = run_hook(session_start, { 'cwd' => dir }, env)
        expect(status).to be_success, err
        expect(out).to include('source freshness is drifted')
        task = File.read(File.join(dir, 'status-argument'))
        expect(task).to start_with('woods:source_status[')
        options = JSON.parse(Base64.strict_decode64(task.split('[', 2).last.delete_suffix(']')))
        expect(options).to eq('output' => output, 'mode' => 'quick')
      end
    end

    it 'checks a Unicode root and output through the Ruby-only fallback under C locale' do
      Dir.mktmpdir('woods-hook') do |parent|
        dir = File.join(parent, 'projet-雪')
        output = 'tmp/索引'
        make_app(dir, tmp_subdir: output)
        bin = restricted_bin(parent, without: %w[jq flock])
        env = status_command(dir, state: 'drifted').merge(
          'WOODS_OUTPUT' => output, 'PATH' => bin, 'LC_ALL' => 'C', 'LANG' => 'C'
        )
        out, err, status = run_hook(session_start, { 'cwd' => dir }, env)
        expect(status).to be_success
        expect(err).to eq('')
        expect(out).to include('source freshness is drifted')
        task = File.read(File.join(dir, 'status-argument'))
        options = JSON.parse(Base64.strict_decode64(task.split('[', 2).last.delete_suffix(']')))
        expect(options).to eq('output' => output, 'mode' => 'quick')
      end
    end
  end
end
