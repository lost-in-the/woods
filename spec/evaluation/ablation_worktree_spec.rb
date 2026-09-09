# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'open3'
require 'fileutils'
require 'woods/evaluation/ablation_worktree'

# Real git, real temp checkouts, no agent involved: the binding ruling is
# that every ablation trial runs in a disposable `git worktree add` checkout
# from a fixed baseline SHA, never in the caller's own working directory, and
# that a reset failure aborts the trial rather than being ignored.
RSpec.describe Woods::Evaluation::AblationWorktree do
  # Initialize a real git repo with one commit and a deterministic branch.
  def init_repo(dir)
    run(dir, 'git', 'init', '--quiet', '--initial-branch', 'main')
    run(dir, 'git', 'config', 'user.email', 'test@example.com')
    run(dir, 'git', 'config', 'user.name', 'Test')
    run(dir, 'git', 'config', 'commit.gpgsign', 'false')
    File.write(File.join(dir, 'README.md'), "hello\n")
    run(dir, 'git', 'add', '.')
    run(dir, 'git', 'commit', '--quiet', '-m', 'initial')
    run(dir, 'git', 'rev-parse', 'HEAD')
  end

  def run(dir, *args)
    out, status = Open3.capture2e(*args, chdir: dir)
    raise "command failed: #{args.join(' ')}\n#{out}" unless status.success?

    out.strip
  end

  def real_executor
    lambda do |command, chdir:|
      stdout, stderr, status = Open3.capture3(command, chdir: chdir)
      [stdout, stderr, status.success?]
    end
  end

  it 'checks out the baseline SHA, yields the path, and removes the worktree afterward' do
    Dir.mktmpdir do |repo|
      sha = init_repo(repo)
      worktree = described_class.new(repo_root: repo, baseline_sha: sha, executor: real_executor)
      yielded_path = nil
      readme_contents = nil

      error = worktree.trial(nil) do |path|
        yielded_path = path
        readme_contents = File.read(File.join(path, 'README.md'))
      end

      expect(error).to be_nil
      expect(readme_contents).to eq("hello\n")
      expect(File.exist?(yielded_path)).to be(false)
      expect(run(repo, 'git', 'worktree', 'list')).not_to include(yielded_path)
    end
  end

  it 'runs the reset command inside the checkout before yielding' do
    Dir.mktmpdir do |repo|
      sha = init_repo(repo)
      worktree = described_class.new(repo_root: repo, baseline_sha: sha, executor: real_executor)
      seen = nil

      worktree.trial('touch reset-marker') { |path| seen = File.exist?(File.join(path, 'reset-marker')) }

      expect(seen).to be(true)
    end
  end

  it 'aborts without yielding and returns an error when the baseline SHA does not exist' do
    Dir.mktmpdir do |repo|
      init_repo(repo)
      worktree = described_class.new(repo_root: repo, baseline_sha: 'not-a-real-sha', executor: real_executor)
      yielded = false

      error = worktree.trial(nil) { yielded = true }

      expect(error).to include('worktree add failed')
      expect(yielded).to be(false)
    end
  end

  it 'aborts without yielding, returns an error, and still tears down the checkout when reset fails' do
    Dir.mktmpdir do |repo|
      sha = init_repo(repo)
      worktree = described_class.new(repo_root: repo, baseline_sha: sha, executor: real_executor)
      yielded = false

      error = worktree.trial('exit 1') { yielded = true }

      expect(error).to include('reset failed')
      expect(yielded).to be(false)
      expect(run(repo, 'git', 'worktree', 'list').lines.size).to eq(1)
    end
  end
end
