# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'open3'
require 'fileutils'
require 'json'
require 'rbconfig'
require 'woods/git_provenance'

RSpec.describe Woods::GitProvenance do
  # Initialize a real git repo with one commit and a deterministic branch.
  def init_repo(dir, branch: 'main')
    run(dir, 'git', 'init', '--quiet', '--initial-branch', branch)
    run(dir, 'git', 'config', 'user.email', 'test@example.com')
    run(dir, 'git', 'config', 'user.name', 'Test')
    # The host's global config leaks into these repos — a machine with
    # commit.gpgsign=true and an unavailable signer (locked agent) hangs
    # or fails every commit below. Pin the hermetic behaviour.
    run(dir, 'git', 'config', 'commit.gpgsign', 'false')
    File.write(File.join(dir, 'README.md'), "hello\n")
    run(dir, 'git', 'add', '.')
    run(dir, 'git', 'commit', '--quiet', '-m', 'initial')
  end

  def run(dir, *args)
    out, status = Open3.capture2e(*args, chdir: dir)
    raise "command failed: #{args.join(' ')}\n#{out}" unless status.success?

    out.strip
  end

  def provenance_subprocess(root, branch: nil, sha: nil)
    script = <<~RUBY
      require 'json'
      require 'woods/git_provenance'

      env = { 'GIT_BRANCH' => ARGV[1], 'GIT_SHA' => ARGV[2] }.compact
      print JSON.generate(Woods::GitProvenance.new(root: ARGV.fetch(0), env: env).to_h)
    RUBY
    lib_dir = File.expand_path('../lib', __dir__)
    Open3.capture3(RbConfig.ruby, '-I', lib_dir, '-e', script, root, branch.to_s, sha.to_s)
  end

  describe '#branch / #sha in a normal checkout' do
    it 'resolves the real branch and commit SHA' do
      Dir.mktmpdir do |dir|
        init_repo(dir, branch: 'main')
        expected_sha = run(dir, 'git', 'rev-parse', 'HEAD')

        provenance = described_class.new(root: dir, env: {})

        expect(provenance.branch).to eq('main')
        expect(provenance.sha).to eq(expected_sha)
        expect(provenance.to_h).to eq(git_branch: 'main', git_sha: expected_sha)
      end
    end

    it 'resolves independently of the process working directory' do
      Dir.mktmpdir do |dir|
        init_repo(dir, branch: 'feature-x')
        expected_sha = run(dir, 'git', 'rev-parse', 'HEAD')

        # Process cwd is the gem root, not `dir` — `-C <root>` must still work.
        provenance = described_class.new(root: dir, env: {})

        expect(provenance.branch).to eq('feature-x')
        expect(provenance.sha).to eq(expected_sha)
      end
    end
  end

  describe '#branch / #sha in a linked worktree (.git is a file)' do
    it 'resolves the worktree branch/sha when the git dir is reachable' do
      Dir.mktmpdir do |parent|
        main = File.join(parent, 'main')
        FileUtils.mkdir_p(main)
        init_repo(main, branch: 'main')

        worktree = File.join(parent, 'wt')
        run(main, 'git', 'worktree', 'add', '--quiet', '-b', 'wt-branch', worktree)

        # Sanity: the worktree's .git is a FILE, not a directory.
        expect(File).to be_file(File.join(worktree, '.git'))

        expected_sha = run(worktree, 'git', 'rev-parse', 'HEAD')
        provenance = described_class.new(root: worktree, env: {})

        expect(provenance.branch).to eq('wt-branch')
        expect(provenance.sha).to eq(expected_sha)
      end
    end
  end

  describe '#branch / #sha when the worktree git dir is unreachable (#137)' do
    it 'emits "unknown" instead of a stale GIT_BRANCH/GIT_SHA env value' do
      Dir.mktmpdir do |dir|
        # Simulate a worktree whose real git dir is not mounted: .git is a file
        # pointing at a path that does not exist in this filesystem.
        File.write(File.join(dir, '.git'), "gitdir: /nonexistent/host/path/.git/worktrees/wt\n")

        stale_env = { 'GIT_BRANCH' => 'baked-stale-branch', 'GIT_SHA' => 'deadbeefstale' }
        provenance = described_class.new(root: dir, env: stale_env)

        # git is installed (CI/dev) but cannot resolve the ref → "unknown",
        # NOT the misleading baked build-arg.
        expect(provenance.branch).to eq('unknown')
        expect(provenance.sha).to eq('unknown')
      end
    end

    it 'does not leak git diagnostics while refusing stale fallback values' do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, '.git'), "gitdir: /nonexistent/host/path/.git/worktrees/wt\n")

        stdout, stderr, status = provenance_subprocess(dir, branch: 'stale', sha: 'deadbeef')

        expect(status).to be_success
        expect(JSON.parse(stdout)).to eq('git_branch' => 'unknown', 'git_sha' => 'unknown')
        expect(stderr).to eq('')
      end
    end
  end

  describe '#branch / #sha when the checkout is not a git working tree' do
    # Pin git's repo discovery to a nonexistent GIT_DIR so `git -C <tmpdir>
    # rev-parse` can't walk UP into a parent checkout (e.g. when TMPDIR nests
    # inside a repo) and resolve a real ref — these cases must deterministically
    # exercise the no-.git fallback. git_working_tree? (a File.exist? check) and
    # the GIT_BRANCH/GIT_SHA lookup (the injected env: hash) are unaffected.
    around do |example|
      original = ENV.fetch('GIT_DIR', nil)
      ENV['GIT_DIR'] = File.join(Dir.tmpdir, 'woods_no_such_gitdir')
      example.run
    ensure
      ENV['GIT_DIR'] = original
    end

    # No .git at the root at all (a source tarball, or a Docker `COPY` that
    # excludes .git) with the git binary present: the GIT_BRANCH/GIT_SHA build
    # args are the only provenance signal, so they ARE honored. This must not be
    # conflated with the unresolvable-worktree case (#137), where a .git IS
    # present and a possibly-stale env value must be suppressed.
    it 'honours GIT_BRANCH/GIT_SHA build args when git is installed but there is no .git' do
      Dir.mktmpdir do |dir|
        # Real git binary on PATH; dir has no .git (git rev-parse will fail).
        env = { 'GIT_BRANCH' => 'release-1.2', 'GIT_SHA' => 'cafebabecafe' }
        provenance = described_class.new(root: dir, env: env)

        expect(provenance.branch).to eq('release-1.2')
        expect(provenance.sha).to eq('cafebabecafe')
      end
    end

    it 'emits "unknown" when there is no .git and no env vars' do
      Dir.mktmpdir do |dir|
        provenance = described_class.new(root: dir, env: {})

        expect(provenance.branch).to eq('unknown')
        expect(provenance.sha).to eq('unknown')
      end
    end

    it 'does not leak expected rev-parse failures to stderr' do
      Dir.mktmpdir do |dir|
        stdout, stderr, status = provenance_subprocess(dir)

        expect(status).to be_success
        expect(JSON.parse(stdout)).to eq('git_branch' => 'unknown', 'git_sha' => 'unknown')
        expect(stderr).to eq('')
      end
    end
  end

  describe '#branch / #sha when git is unavailable' do
    before do
      # Force both rev-parse and the binary probe to fail, simulating an
      # environment with no usable git.
      allow(Open3).to receive(:capture3).and_raise(Errno::ENOENT)
    end

    it 'honours GIT_BRANCH/GIT_SHA env vars as the documented no-git fallback' do
      Dir.mktmpdir do |dir|
        env = { 'GIT_BRANCH' => 'ci-branch', 'GIT_SHA' => 'abc123' }
        provenance = described_class.new(root: dir, env: env)

        expect(provenance.branch).to eq('ci-branch')
        expect(provenance.sha).to eq('abc123')
      end
    end

    it 'emits "unknown" when no env vars are set' do
      Dir.mktmpdir do |dir|
        provenance = described_class.new(root: dir, env: {})

        expect(provenance.branch).to eq('unknown')
        expect(provenance.sha).to eq('unknown')
      end
    end
  end
end
