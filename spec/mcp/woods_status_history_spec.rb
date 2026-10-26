# frozen_string_literal: true

require 'spec_helper'
require 'woods'
require 'woods/mcp/server'
require 'open3'
require 'tmpdir'
require 'fileutils'

RSpec.describe 'woods_status git history staleness' do
  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with('WOODS_NO_UPDATE_CHECK').and_return(nil)
  end

  def git(dir, *args)
    out, status = Open3.capture2e('git', *args, chdir: dir)
    raise "git #{args.join(' ')} failed: #{out}" unless status.success?

    out.strip
  end

  def init_repo(dir)
    FileUtils.mkdir_p(dir)
    git(dir, 'init', '--quiet', '--initial-branch', 'main')
    git(dir, 'config', 'user.email', 'test@example.com')
    git(dir, 'config', 'user.name', 'Test')
    git(dir, 'config', 'commit.gpgsign', 'false')
    File.write(File.join(dir, 'README.md'), "hello\n")
    git(dir, 'add', '.')
    git(dir, 'commit', '--quiet', '-m', 'initial')
  end

  def empty_commit(dir)
    git(dir, 'commit', '--quiet', '--allow-empty', '-m', 'no source change')
  end

  def history_for(index_dir, published_sha, source_state: 'current', root: :enclosing)
    FileUtils.mkdir_p(index_dir)
    root = File.expand_path('../..', index_dir) if root == :enclosing
    manifest = { 'git_sha' => published_sha, 'extracted_at' => nil, 'counts' => {} }
    freshness = { 'state' => source_state, 'complete' => true, 'recorded_root' => root }
    reader = double('reader', manifest: manifest, source_freshness: freshness)
    Woods::MCP::Server.build_status(reader: reader, retriever: nil, index_dir: index_dir)[:index]
  end

  it 'is current while HEAD still equals the published sha' do
    Dir.mktmpdir do |repo|
      init_repo(repo)
      index = history_for(File.join(repo, 'tmp', 'woods'), git(repo, 'rev-parse', 'HEAD'))

      expect(index[:history]).to include(state: 'current')
    end
  end

  it 'is stale after a commit with no source change, even when source freshness is current' do
    Dir.mktmpdir do |repo|
      init_repo(repo)
      published = git(repo, 'rev-parse', 'HEAD')
      empty_commit(repo)
      index = history_for(File.join(repo, 'tmp', 'woods'), published, source_state: 'current')

      expect(index[:source_freshness]['state']).to eq('current')
      expect(index[:history]).to eq(state: 'stale', reason: 'head_moved',
                                    published_sha: published, head_sha: git(repo, 'rev-parse', 'HEAD'))
    end
  end

  it 'compares a detached HEAD like any other' do
    Dir.mktmpdir do |repo|
      init_repo(repo)
      published = git(repo, 'rev-parse', 'HEAD')
      empty_commit(repo)
      git(repo, 'checkout', '--quiet', '--detach', published)

      expect(history_for(File.join(repo, 'tmp', 'woods'), published)[:history]).to include(state: 'current')

      git(repo, 'checkout', '--quiet', 'main')
      git(repo, 'checkout', '--quiet', '--detach')
      expect(history_for(File.join(repo, 'tmp', 'woods'), 'f' * 40)[:history]).to include(state: 'stale')
    end
  end

  it 'is unknown, not stale, when the directory has no git history to compare' do
    Dir.mktmpdir do |dir|
      allow(ENV).to receive(:[]).with('GIT_SHA').and_return('b' * 40)
      # Stops git walking up into a checkout that happens to contain TMPDIR.
      original = ENV.fetch('GIT_DIR', nil)
      ENV['GIT_DIR'] = File.join(dir, 'no_such_gitdir')
      begin
        index = history_for(File.join(dir, 'woods'), 'a' * 40)
      ensure
        original.nil? ? ENV.delete('GIT_DIR') : ENV['GIT_DIR'] = original
      end

      expect(index[:history]).to eq(state: 'unknown', reason: 'head_unresolved', published_sha: 'a' * 40)
    end
  end

  it 'is unknown when the manifest records no usable sha' do
    Dir.mktmpdir do |repo|
      init_repo(repo)
      index_dir = File.join(repo, 'tmp', 'woods')

      expect(history_for(index_dir, nil)[:history]).to eq(state: 'unknown', reason: 'published_sha_missing')
      expect(history_for(index_dir, 'unknown')[:history])
        .to eq(state: 'unknown', reason: 'published_sha_unknown', published_sha: 'unknown')
    end
  end

  it 'follows the linked worktree HEAD, not the primary checkout HEAD' do
    Dir.mktmpdir do |parent|
      main = File.join(parent, 'main')
      init_repo(main)
      worktree = File.join(parent, 'wt')
      git(main, 'worktree', 'add', '--quiet', '-b', 'wt-branch', worktree)
      published = git(worktree, 'rev-parse', 'HEAD')
      worktree_index = File.join(worktree, 'tmp', 'woods')

      empty_commit(main)
      expect(history_for(worktree_index, published)[:history]).to include(state: 'current')

      empty_commit(worktree)
      expect(history_for(worktree_index, published)[:history])
        .to include(state: 'stale', head_sha: git(worktree, 'rev-parse', 'HEAD'))
    end
  end

  it 'honours WOODS_GIT_DIR like every other Woods git call' do
    Dir.mktmpdir do |parent|
      repo = File.join(parent, 'repo')
      init_repo(repo)
      published = git(repo, 'rev-parse', 'HEAD')
      empty_commit(repo)
      allow(ENV).to receive(:[]).with('WOODS_GIT_DIR').and_return(File.join(repo, '.git'))

      expect(history_for(File.join(parent, 'elsewhere'), published)[:history]).to include(state: 'stale')
    end
  end

  it 'never reports the repository that merely encloses the index directory' do
    Dir.mktmpdir do |parent|
      other = File.join(parent, 'other')
      app = File.join(parent, 'app')
      init_repo(other)
      init_repo(app)
      published = git(app, 'rev-parse', 'HEAD')
      empty_commit(other)
      index_dir = File.join(other, 'tmp', 'woods')

      index = history_for(index_dir, published, root: app)
      expect(index[:history]).to include(state: 'current', head_sha: published)
      expect(index[:head_git_sha]).to eq(published)

      unrecorded = history_for(index_dir, published, root: nil)
      expect(unrecorded[:history]).to eq(state: 'unknown', reason: 'root_not_recorded', published_sha: published)
      expect(unrecorded).not_to have_key(:head_git_sha)
    end
  end

  it 'is unknown when the recorded root is not reachable from this process' do
    Dir.mktmpdir do |repo|
      init_repo(repo)
      index = history_for(File.join(repo, 'tmp', 'woods'), git(repo, 'rev-parse', 'HEAD'), root: '/container/app')

      expect(index[:history]).to include(state: 'unknown', reason: 'root_unreachable')
      expect(index).not_to have_key(:git_sha_matches_head)
    end
  end

  it 'keeps the existing head comparison keys' do
    Dir.mktmpdir do |repo|
      init_repo(repo)
      published = git(repo, 'rev-parse', 'HEAD')
      empty_commit(repo)
      index = history_for(File.join(repo, 'tmp', 'woods'), published)

      expect(index).to include(git_sha_matches_head: false, head_git_sha: git(repo, 'rev-parse', 'HEAD'))
    end
  end
end
