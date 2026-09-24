# frozen_string_literal: true

require 'spec_helper'
require 'rake'
require 'tmpdir'
require 'fileutils'
require 'open3'
require 'pathname'
require 'stringio'
require 'woods/path_dispatcher'

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
    # gc.autoDetach makes `git commit` spawn a background gc that keeps
    # writing .git/objects after the command returns; the mktmpdir cleanup
    # then races it and dies with Errno::ENOTEMPTY on loaded runners (CI,
    # Ruby 3.2 job). Defuse the detach so every gc work happens inline.
    run(dir, 'git', 'config', 'gc.autoDetach', 'false')
    run(dir, 'git', 'config', 'gc.auto', '0')
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

      changed, = Woods::RakeHelpers.woods_changed_paths_for_range('HEAD~1..HEAD', root: dir)

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

      changed, = Woods::RakeHelpers.woods_changed_paths_for_range('HEAD~1..HEAD', root: dir)

      expect(changed).to eq(['app/models/user.rb'])
    end
  end

  it 'returns only application-relative changes for a Rails app nested in a repository' do
    Dir.mktmpdir('woods_nested_incremental_git') do |dir|
      init_repo(dir)
      app = File.join(dir, 'services/shop')
      originals = %w[old.rb deleted.rb moved_out.rb héllo.rb] + ["line\nbreak.rb"]
      originals.each do |name|
        path = File.join(app, 'app/models', name)
        FileUtils.mkdir_p(File.dirname(path))
        File.binwrite(path, "class Example; end\n")
      end
      FileUtils.mkdir_p(File.join(dir, 'services/other/app/models'))
      File.write(File.join(dir, 'services/other/app/models/moved_in.rb'), 'class Incoming; end')
      run(dir, 'git', 'add', '-A')
      run(dir, 'git', 'commit', '--quiet', '-m', 'initial')

      run(dir, 'git', 'mv', 'services/shop/app/models/old.rb', 'services/shop/app/models/new.rb')
      run(dir, 'git', 'mv', 'services/shop/app/models/moved_out.rb', 'services/other/app/models/moved_out.rb')
      run(dir, 'git', 'mv', 'services/other/app/models/moved_in.rb', 'services/shop/app/models/moved_in.rb')
      File.unlink(File.join(app, 'app/models/deleted.rb'))
      ['héllo.rb', "line\nbreak.rb"].each { |name| File.binwrite(File.join(app, 'app/models', name), 'changed') }
      File.write(File.join(dir, 'services/other/app/models/unrelated.rb'), 'class Unrelated; end')
      run(dir, 'git', 'add', '-A')
      run(dir, 'git', 'commit', '--quiet', '-m', 'nested changes')

      changed, failure = Woods::RakeHelpers.woods_changed_paths_for_range('HEAD~1..HEAD', root: app)

      expect(failure).to be_nil
      expect(changed).to match_array((originals + %w[new.rb moved_in.rb]).map { |name| "app/models/#{name}" })
      expect(changed).to all(satisfy { |path| Woods::PathDispatcher.new.relevant?(path) })
    end
  end

  describe 'explicit changed files at the task boundary' do
    let(:repo_dir) { Dir.mktmpdir('woods_incremental_paths') }

    after { FileUtils.remove_entry(repo_dir) }

    it 'normalizes and contains paths before filtering and preserves missing paths' do
      require 'woods/extractor'
      stub_const('Rails', double('Rails', root: Pathname.new("#{repo_dir}//")))
      paths = ['./app/models/user.rb', "#{repo_dir}/app/models/user.rb", './config//./routes.rb',
               'app/models/../models/deleted.rb', "#{repo_dir}-other/app/models/outsider.rb",
               '../other/app/models/outsider.rb', 'app/../../../other/app/models/outsider.rb',
               './notes/unrelated.txt']
      stub_const('ENV', ENV.to_h.merge('CHANGED_FILES' => paths.join(','), 'WOODS_OUTPUT' => repo_dir))
      expect(Woods::RakeHelpers).not_to receive(:woods_changed_paths_for_range)
      allow(Woods::RakeHelpers).to receive(:woods_daemon_coverage).and_return(:absent)
      allow(Woods::RakeHelpers).to receive(:woods_with_extraction_lock).and_yield
      extractor = instance_double(Woods::Extractor, raise_on_publication_failure!: nil)
      allow(Woods::Extractor).to receive(:new).with(output_dir: repo_dir).and_return(extractor)
      expect(extractor).to receive(:extract_changed)
        .with(%w[app/models/user.rb config/routes.rb app/models/deleted.rb]).and_return([])

      # Isolate task loading so another spec's Rake application cannot add
      # duplicate actions; execute skips the host-only :environment prerequisite.
      previous = Rake.application
      Rake.application = Rake::Application.new
      load File.expand_path('../../lib/tasks/woods.rake', __dir__)
      expect { Rake::Task['woods:incremental'].execute }.to output(/3 changed files/).to_stdout
    ensure
      Rake.application = previous if previous
    end
  end

  describe 'CI range selection' do
    before do
      values = ENV.to_h.except('CI_COMMIT_BEFORE_SHA', 'CI_COMMIT_SHA', 'GITHUB_BASE_REF')
      stub_const('ENV', values)
    end

    it 'ignores empty and whitespace-only CI variables' do
      ENV.merge!('CI_COMMIT_BEFORE_SHA' => " \t", 'CI_COMMIT_SHA' => '', 'GITHUB_BASE_REF' => "\n ")
      expect(Woods::RakeHelpers.woods_incremental_range).to eq('HEAD~1')
    end

    it 'uses a GitHub base when the GitLab before-SHA is blank' do
      ENV.merge!('CI_COMMIT_BEFORE_SHA' => '', 'GITHUB_BASE_REF' => ' main ')
      expect(Woods::RakeHelpers.woods_incremental_range).to eq('origin/main...HEAD')
    end

    it 'uses HEAD when GitLab provides a before-SHA and a blank current SHA' do
      ENV.merge!('CI_COMMIT_BEFORE_SHA' => 'abc123', 'CI_COMMIT_SHA' => " \t")
      expect(Woods::RakeHelpers.woods_incremental_range).to eq('abc123..HEAD')
    end

    it 'retains nonempty ranges for Git to validate rather than falling back' do
      ENV.merge!('CI_COMMIT_BEFORE_SHA' => 'bad-revision', 'CI_COMMIT_SHA' => 'other-bad-revision',
                 'GITHUB_BASE_REF' => 'main')
      expect(Woods::RakeHelpers.woods_incremental_range).to eq('bad-revision..other-bad-revision')
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
      paths, failure = Woods::RakeHelpers.woods_changed_paths_for_range('HEAD~1..HEAD')

      expect(paths).to be_nil
      expect(failure).to be_a(String)
      expect(failure).not_to be_empty
      expect(failure).to match(/git exited \d+/)
    end

    it 'exits non-zero when the range fails and no daemon covers the index' do
      expect { Woods::RakeHelpers.woods_incremental_changed_paths(repo_dir) }
        .to output(/HEAD~1/).to_stderr
        .and raise_error(SystemExit) { |exit_error| expect(exit_error.status).to eq(1) }
    end

    %w[CI_COMMIT_BEFORE_SHA GITHUB_BASE_REF].each do |key|
      it "fails clearly for a nonempty invalid #{key}" do
        ENV[key] = 'unresolvable-revision'

        expect { Woods::RakeHelpers.woods_incremental_changed_paths(repo_dir) }
          .to output(/unresolvable-revision/).to_stderr
          .and raise_error(SystemExit) { |error| expect(error.status).to eq(1) }
      end
    end

    it 'stands down with exit 0 for a failed range when a running daemon covers the index' do
      live_daemon_status!('running')

      expect { Woods::RakeHelpers.woods_incremental_changed_paths(repo_dir) }
        .to output(/daemon/).to_stdout
        .and raise_error(SystemExit) { |exit_error| expect(exit_error.status).to eq(0) }
    end

    it 'does not stand down for a degraded daemon: a failed range still exits 1' do
      live_daemon_status!('degraded')

      expect { Woods::RakeHelpers.woods_incremental_changed_paths(repo_dir) }
        .to output(/HEAD~1/).to_stderr
        .and output('').to_stdout
        .and raise_error(SystemExit) { |exit_error| expect(exit_error.status).to eq(1) }
    end

    %w[running degraded].each do |state|
      it "keeps failed-range coverage semantics for a trusted foreign #{state} daemon (#321)" do
        require 'woods/watch/status'
        Woods::Watch::Status.new(output_dir: repo_dir).write(state: state.to_sym, host: 'another-container')
        allow(ENV).to receive(:[]).and_call_original
        allow(ENV).to receive(:[]).with('WOODS_WATCH_TRUST_FOREIGN_HOST').and_return('1')

        expect { Woods::RakeHelpers.woods_incremental_changed_paths(repo_dir) }
          .to raise_error(SystemExit) { |error| expect(error.status).to eq(state == 'running' ? 0 : 1) }
      end
    end

    # ── A missing git binary is the same decision, not a crash (INF-12) ──
    #
    # `Open3.capture3` raises Errno::ENOENT when git is absent (a slim
    # container image, git removed after checkout). Unrescued, the task died
    # with a backtrace: exit non-zero — the safe direction — but the
    # `:running`-daemon stand-down branch was unreachable, so a daemon-covered
    # tree that would legitimately exit 0 failed its hook, and the operator got
    # a stack trace instead of the remediation text.
    describe 'a missing git binary' do
      before do
        require 'open3'
        allow(Open3).to receive(:capture3).and_raise(Errno::ENOENT, 'No such file or directory - git')
      end

      it 'returns the same [nil, failure] shape the decision matrix reads' do
        paths, failure = Woods::RakeHelpers.woods_changed_paths_for_range('HEAD~1..HEAD')

        expect(paths).to be_nil
        expect(failure).to be_a(String)
        expect(failure).to include('git unavailable')
      end

      it 'exits 1 with the remediation text when no daemon covers the index' do
        expect { Woods::RakeHelpers.woods_incremental_changed_paths(repo_dir) }
          .to output(/git unavailable/).to_stderr
          .and raise_error(SystemExit) { |exit_error| expect(exit_error.status).to eq(1) }
      end

      it 'stands down with exit 0 when a running daemon covers the index' do
        live_daemon_status!('running')

        expect { Woods::RakeHelpers.woods_incremental_changed_paths(repo_dir) }
          .to output(/daemon/).to_stdout
          .and raise_error(SystemExit) { |exit_error| expect(exit_error.status).to eq(0) }
      end
    end
  end

  # ── The git directory override reaches the range lookup (B-186/B-181) ──
  #
  # `WOODS_GIT_DIR` exists because a container over a linked worktree can mount
  # complete shared Git layout at a new path and explicitly select the
  # worktree-specific directory inside it. Enrichment and manifest provenance
  # both honour it. The incremental range lookup is the third git call Woods makes, and it ran
  # `git -C <root>` directly, so `woods:incremental` still exited 1 in exactly
  # the container the override was added for.
  describe 'WOODS_GIT_DIR' do
    let(:scratch) { Dir.mktmpdir('woods_incremental_override') }
    let(:main_repo) { File.join(scratch, 'main') }
    let(:worktree) { File.join(scratch, 'wt') }

    before do
      FileUtils.mkdir_p(File.join(main_repo, 'app', 'models'))
      init_repo(main_repo)
      File.write(File.join(main_repo, 'app/models/user.rb'), "class User; end\n")
      run(main_repo, 'git', 'add', '-A')
      run(main_repo, 'git', 'commit', '--quiet', '-m', 'initial')
      File.write(File.join(main_repo, 'app/models/user.rb'), "class User\nend\n")
      run(main_repo, 'git', 'add', '-A')
      run(main_repo, 'git', 'commit', '--quiet', '-m', 'edit')
      run(main_repo, 'git', 'worktree', 'add', '--quiet', worktree, '-b', 'feature')
      File.write(File.join(worktree, 'app/models/feature.rb'), "class Feature; end\n")
      run(worktree, 'git', 'add', '-A')
      run(worktree, 'git', 'commit', '--quiet', '-m', 'feature only')
      private_gitdir = run(worktree, 'git', 'rev-parse', '--absolute-git-dir')
      mounted_common = File.join(scratch, 'mounted-common')
      @mounted_gitdir = File.join(mounted_common, 'worktrees', File.basename(private_gitdir))
      FileUtils.mv(File.join(main_repo, '.git'), mounted_common)
    end

    after { FileUtils.rm_rf(scratch) }

    it 'reports a failure without the override, because no ref resolves' do
      paths, failure = Woods::RakeHelpers.woods_changed_paths_for_range('HEAD~1..HEAD', root: worktree)

      expect(paths).to be_nil
      expect(failure).to be_a(String)
    end

    it 'resolves the feature range through its relocated worktree-specific git directory' do
      stub_const('ENV', ENV.to_h.merge('WOODS_GIT_DIR' => @mounted_gitdir))

      paths, failure = Woods::RakeHelpers.woods_changed_paths_for_range('HEAD~1..HEAD', root: worktree)

      expect(failure).to be_nil
      expect(paths).to eq(['app/models/feature.rb'])
    end
  end
end
