# frozen_string_literal: true

require 'spec_helper'
require 'fileutils'
require 'open3'
require 'pathname'
require 'tmpdir'
require 'woods'
require 'woods/extractor'
require 'woods/git_provenance'

# Git enrichment against a linked worktree whose git directory is out of reach.
#
# B-186: with GIT_DIR pointing at a linked worktree's private git directory,
# `rev-parse --git-dir` succeeds while no ref resolves, because the private
# directory's `commondir` is a relative pointer that resolves outside the
# mount. `git log` then exits 0 with no output, and every unit was written with
# `commit_count: 0` and `change_frequency: new`, indistinguishable from a file
# that was never committed, where a fully absent git directory correctly omits
# the keys.
#
# B-181: `WOODS_GIT_DIR` explicitly selects a git directory. For a linked
# worktree, preserve its private HEAD and the complete shared Git layout.
RSpec.describe 'Git enrichment over a linked worktree' do
  let(:scratch) { Dir.mktmpdir('woods_git_worktree') }
  let(:main_repo) { File.join(scratch, 'main') }
  let(:worktree) { File.join(scratch, 'wt') }
  let(:app_file) { File.join(worktree, 'app', 'models', 'post.rb') }
  let(:logger) { instance_spy(Logger) }
  let(:extractor) { Woods::Extractor.new(output_dir: File.join(scratch, 'out')) }

  before do
    require 'active_support'
    require 'active_support/core_ext/numeric/time'
    require 'active_support/core_ext/string/access'
    require 'active_support/core_ext/time'
    Woods.configuration ||= Woods::Configuration.new

    build_main_repo
    add_worktree
    commit_feature_change

    stub_const('Rails', double('Rails'))
    allow(Rails).to receive(:root).and_return(Pathname.new(worktree))
    allow(Rails).to receive(:logger).and_return(logger)
  end

  after do
    FileUtils.rm_rf(scratch)
    Woods.configuration = Woods::Configuration.new
  end

  # A machine with global commit signing, a global hooksPath, or a system
  # gitconfig would otherwise decide whether this spec passes. Every git call
  # below runs with neither config file in scope.
  def hermetic_git_env
    { 'GIT_CONFIG_GLOBAL' => '/dev/null', 'GIT_CONFIG_NOSYSTEM' => '1' }
  end

  def run!(*args, chdir:)
    output, status = Open3.capture2e(hermetic_git_env, *args, chdir: chdir)
    raise "command failed: #{args.join(' ')}\n#{output}" unless status.success?

    output
  end

  def build_main_repo
    FileUtils.mkdir_p(File.join(main_repo, 'app', 'models'))
    run!('git', 'init', '--quiet', '--initial-branch', 'main', '.', chdir: main_repo)
    run!('git', 'config', 'user.email', 'specs@example.test', chdir: main_repo)
    run!('git', 'config', 'user.name', 'Specs', chdir: main_repo)
    # A background gc keeps writing into .git after `git commit` returns, and
    # the tmpdir cleanup then races it into Errno::ENOTEMPTY.
    run!('git', 'config', 'gc.autoDetach', 'false', chdir: main_repo)
    run!('git', 'config', 'gc.auto', '0', chdir: main_repo)
    File.write(File.join(main_repo, 'app', 'models', 'post.rb'), "class Post\nend\n")
    run!('git', 'add', '.', chdir: main_repo)
    run!('git', 'commit', '--quiet', '-m', 'add post', chdir: main_repo)
  end

  def add_worktree
    run!('git', 'worktree', 'add', '--quiet', worktree, '-b', 'feature', chdir: main_repo)
  end

  def commit_feature_change
    File.write(app_file, "class Post\n  def feature; end\nend\n")
    run!('git', 'add', '.', chdir: worktree)
    run!('git', 'commit', '--quiet', '-m', 'feature post', chdir: worktree)
    @feature_sha = run!('git', 'rev-parse', 'HEAD', chdir: worktree).strip
  end

  # The private git directory the worktree's .git file points at.
  def private_gitdir
    File.read(File.join(worktree, '.git')).sub('gitdir:', '').strip
  end

  # Shape 1: the pointer names a path that is not there at all, which is what a
  # container sees when the host worktree path is not mounted.
  def break_gitdir_pointer!
    File.write(File.join(worktree, '.git'), "gitdir: #{File.join(scratch, 'not-mounted', 'wt')}\n")
  end

  # Shape 2: the private directory is right there, but its commondir points at
  # something that is not the repository. `rev-parse --git-dir` answers, every
  # ref lookup does not, and `git log` exits 0 with nothing to say.
  def break_commondir!
    unreachable = File.join(scratch, 'unreachable-common')
    FileUtils.mkdir_p(File.join(unreachable, 'objects'))
    FileUtils.mkdir_p(File.join(unreachable, 'refs'))
    File.write(File.join(private_gitdir, 'commondir'), "#{unreachable}\n")
  end

  def enrich!
    unit = Woods::ExtractedUnit.new(type: :model, identifier: 'Post', file_path: app_file)
    extractor.instance_variable_set(:@results, { models: [unit] })
    extractor.send(:enrich_with_git_data)
    unit
  end

  describe 'when the worktree gitdir pointer names a missing path' do
    before { break_gitdir_pointer! }

    it 'omits the git keys rather than writing zero commits' do
      unit = enrich!

      expect(unit.metadata).not_to have_key(:git)
    end

    it 'logs one warning naming the cause' do
      enrich!

      expect(logger).to have_received(:warn).with(%r{WOODS_GIT_DIR.*worktrees/<id>}).once
    end

    it 'records provenance as unknown' do
      provenance = Woods::GitProvenance.new(root: worktree, env: {}).to_h

      expect(provenance).to eq(git_branch: 'unknown', git_sha: 'unknown')
    end
  end

  describe 'when the private gitdir is present but its commondir is unreachable' do
    before { break_commondir! }

    it 'omits the git keys rather than writing zero commits and change_frequency new' do
      unit = enrich!

      expect(unit.metadata).not_to have_key(:git)
    end

    it 'logs one warning naming the cause' do
      enrich!

      expect(logger).to have_received(:warn).with(%r{WOODS_GIT_DIR.*worktrees/<id>}).once
    end

    it 'records provenance as unknown' do
      provenance = Woods::GitProvenance.new(root: worktree, env: {}).to_h

      expect(provenance).to eq(git_branch: 'unknown', git_sha: 'unknown')
    end
  end

  describe 'WOODS_GIT_DIR' do
    let(:mounted_common) { File.join(scratch, 'mounted-common') }

    before do
      # The worktree ID is metadata, not the branch name ('wt' vs 'feature').
      @mounted_gitdir = File.join(mounted_common, 'worktrees', File.basename(private_gitdir))
      FileUtils.cp_r(File.join(main_repo, '.git'), mounted_common)
    end

    it 'wins over an unreachable commondir and restores the git keys' do
      break_commondir!
      stub_const('ENV', ENV.to_h.merge('WOODS_GIT_DIR' => @mounted_gitdir))

      unit = enrich!

      expect(unit.metadata[:git][:commit_count]).to eq(2)
      expect(unit.metadata[:git][:recent_commits].map { |commit| commit[:message] })
        .to eq(['feature post', 'add post'])
    end

    it 'uses the relocated layout when the original shared directory is absent' do
      FileUtils.rm_rf(File.join(main_repo, '.git'))
      stub_const('ENV', ENV.to_h.merge('WOODS_GIT_DIR' => @mounted_gitdir))

      unit = enrich!

      expect(unit.metadata[:git][:recent_commits].first).to include(sha: @feature_sha[0, 8], message: 'feature post')
    end

    it 'restores provenance for the manifest' do
      break_commondir!

      provenance = Woods::GitProvenance.new(root: worktree, env: { 'WOODS_GIT_DIR' => @mounted_gitdir }).to_h

      expect(provenance).to eq(git_branch: 'feature', git_sha: @feature_sha)
    end

    it 'honors an explicit shared-root override without guessing the worktree branch' do
      provenance = Woods::GitProvenance.new(root: worktree, env: { 'WOODS_GIT_DIR' => mounted_common }).to_h
      main_sha = run!('git', 'rev-parse', 'HEAD', chdir: main_repo).strip

      expect(provenance).to eq(git_branch: 'main', git_sha: main_sha)
    end

    it 'is ignored when it is empty' do
      stub_const('ENV', ENV.to_h.merge('WOODS_GIT_DIR' => ''))

      unit = enrich!

      expect(unit.metadata[:git][:commit_count]).to eq(2)
    end
  end

  describe 'a healthy linked worktree' do
    it 'still enriches without any override' do
      unit = enrich!

      expect(unit.metadata[:git][:commit_count]).to eq(2)
    end

    it 'records the exact feature branch and SHA without an override' do
      provenance = Woods::GitProvenance.new(root: worktree, env: {}).to_h

      expect(provenance).to eq(git_branch: 'feature', git_sha: @feature_sha)
    end

    it 'logs no warning' do
      enrich!

      expect(logger).not_to have_received(:warn)
    end
  end
end
