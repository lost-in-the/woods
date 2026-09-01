# frozen_string_literal: true

require 'spec_helper'
require 'rake'
require 'tmpdir'
require 'fileutils'
require 'open3'
require 'pathname'
require 'stringio'

# `woods:incremental`'s three git-diff branches used to parse
# `git diff --name-only` with `output.lines.map(&:strip)`. That corrupts three
# cases at once: a path containing a newline splits into two; a non-ASCII path
# is octal-escaped inside quotes by git's default `core.quotePath` (and the
# dispatcher then can't match it to any rule); and a rename reports only the
# new path, so the old path's unit is never pruned. `woods_changed_paths_for_range`
# replaces all three call sites with one NUL-delimited, rename-decomposed parse.
RSpec.describe 'woods:incremental changed-path parsing' do
  before { load File.expand_path('../../lib/tasks/woods.rake', __dir__) }

  def run(dir, *args)
    out, status = Open3.capture2e(*args, chdir: dir)
    raise "command failed: #{args.join(' ')}\n#{out}" unless status.success?

    out.strip
  end

  def init_repo(dir)
    run(dir, 'git', 'init', '--quiet', '--initial-branch', 'main')
    run(dir, 'git', 'config', 'user.email', 'test@example.com')
    run(dir, 'git', 'config', 'user.name', 'Test')
    # The host's global config leaks into a fixture repo — a signer-required
    # commit.gpgsign=true hangs every commit below on a machine with a locked
    # agent. Pin the hermetic behaviour, same as spec/git_provenance_spec.rb.
    run(dir, 'git', 'config', 'commit.gpgsign', 'false')
  end

  it 'reaches both halves of a rename and an unescaped UTF-8 path' do
    Dir.mktmpdir('woods_incremental_git') do |dir|
      init_repo(dir)
      FileUtils.mkdir_p(File.join(dir, 'app/models'))
      File.write(File.join(dir, 'app/models/foo.rb'), "class Foo; end\n")
      File.write(File.join(dir, 'app/models/héllo.rb'), 'hello')
      run(dir, 'git', 'add', '-A')
      run(dir, 'git', 'commit', '--quiet', '-m', 'initial')

      run(dir, 'git', 'mv', 'app/models/foo.rb', 'app/models/bar.rb')
      File.open(File.join(dir, 'app/models/héllo.rb'), 'a') { |f| f.write('!') }
      run(dir, 'git', 'add', '-A')
      run(dir, 'git', 'commit', '--quiet', '-m', 'rename and edit')

      changed, = Object.new.send(:woods_changed_paths_for_range, 'HEAD~1..HEAD', root: dir)

      # Both halves of the rename reach the change set — the new path (so the
      # unit is re-extracted) and the old one (so its unit is pruned).
      expect(changed).to include('app/models/bar.rb')
      expect(changed).to include('app/models/foo.rb')

      # Unescaped, not the octal-quoted form core.quotePath produces by default.
      expect(changed).to include('app/models/héllo.rb')
      expect(changed.grep(/\\\d{3}/)).to be_empty
    end
  end

  it 'never returns a corrupted (blank or partial) entry' do
    Dir.mktmpdir('woods_incremental_git') do |dir|
      init_repo(dir)
      FileUtils.mkdir_p(File.join(dir, 'app/models'))
      File.write(File.join(dir, 'app/models/user.rb'), "class User; end\n")
      run(dir, 'git', 'add', '-A')
      run(dir, 'git', 'commit', '--quiet', '-m', 'initial')

      File.write(File.join(dir, 'app/models/user.rb'), "class User\nend\n")
      run(dir, 'git', 'add', '-A')
      run(dir, 'git', 'commit', '--quiet', '-m', 'edit')

      changed, = Object.new.send(:woods_changed_paths_for_range, 'HEAD~1..HEAD', root: dir)

      expect(changed).to eq(['app/models/user.rb'])
    end
  end

  # ── Unresolvable ranges fail closed (M1) ──────────────────────────────
  #
  # `woods_changed_paths_for_range` used `Open3.capture2` and discarded the
  # child status, so an unresolvable range — a GitLab zero-SHA, an unfetched
  # GitHub base ref, garbage — read as "nothing changed": the task printed
  # "No relevant files changed" and exited 0 while the sync never ran, and the
  # degraded-daemon extract-anyway branch was unreachable. The helper now
  # carries the failure out, and the task's decision runs the daemon-coverage
  # check BEFORE any empty-range exit: a `:running` daemon stands down with a
  # printed reason, everything else exits 1 naming the range.
  describe 'unresolvable diff ranges fail closed (M1)' do
    let(:repo_dir) { Dir.mktmpdir('woods_incremental_git') }

    around do |example|
      keys = %w[CHANGED_FILES CI_COMMIT_BEFORE_SHA CI_COMMIT_SHA GITHUB_BASE_REF WOODS_IGNORE_WATCH]
      saved = keys.to_h { |key| [key, ENV.fetch(key, nil)] }
      keys.each { |key| ENV.delete(key) }
      example.run
    ensure
      saved.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
      FileUtils.rm_rf(repo_dir)
    end

    before do
      stub_const('Rails', double('Rails', root: Pathname.new(repo_dir)))
      init_repo(repo_dir)
      FileUtils.mkdir_p(File.join(repo_dir, 'app/models'))
      File.write(File.join(repo_dir, 'app/models/foo.rb'), "class Foo; end\n")
      run(repo_dir, 'git', 'add', '-A')
      run(repo_dir, 'git', 'commit', '--quiet', '-m', 'initial')
    end

    # A status record Status#alive? believes; `state` selects running/degraded.
    def live_daemon_status!(state)
      require 'woods/watch/status'
      require 'time'
      File.write(
        File.join(repo_dir, Woods::Watch::Status::FILENAME),
        JSON.generate(
          'state' => state,
          'pid' => Process.pid,
          'host' => Woods::Watch::Status.host_identity,
          'updated_at' => Time.now.utc.iso8601
        )
      )
    end

    it 'reports the failure instead of an empty change set' do
      paths, failure = Object.new.send(:woods_changed_paths_for_range, 'HEAD~1..HEAD')

      expect(paths).to be_nil
      expect(failure).to be_a(String)
      expect(failure).not_to be_empty
      expect(failure).to match(/git exited \d+/)
    end

    it 'exits non-zero when the range fails and no daemon covers the index' do
      expect { Object.new.send(:woods_incremental_changed_paths, repo_dir) }
        .to output(/HEAD~1/).to_stderr
        .and raise_error(SystemExit) { |exit_error| expect(exit_error.status).to eq(1) }
    end

    it 'stands down with exit 0 for a failed range when a running daemon covers the index' do
      live_daemon_status!('running')

      expect { Object.new.send(:woods_incremental_changed_paths, repo_dir) }
        .to output(/daemon/).to_stdout
        .and raise_error(SystemExit) { |exit_error| expect(exit_error.status).to eq(0) }
    end

    it 'does not stand down for a degraded daemon: a failed range still exits 1' do
      live_daemon_status!('degraded')

      expect { Object.new.send(:woods_incremental_changed_paths, repo_dir) }
        .to output(/HEAD~1/).to_stderr
        .and output('').to_stdout
        .and raise_error(SystemExit) { |exit_error| expect(exit_error.status).to eq(1) }
    end
  end
end
