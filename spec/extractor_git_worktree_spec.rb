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
# `commit_count: 0` and `change_frequency: new` — indistinguishable from a file
# that was never committed, where a fully absent git directory correctly omits
# the keys.
#
# B-181: the escape hatch. `WOODS_GIT_DIR` names the canonical git directory
# and wins over whatever the worktree pointer says.
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

    stub_const('Rails', double('Rails'))
    allow(Rails).to receive(:root).and_return(Pathname.new(worktree))
    allow(Rails).to receive(:logger).and_return(logger)
  end

  after do
    FileUtils.rm_rf(scratch)
    Woods.configuration = Woods::Configuration.new
  end

  def run!(*args, chdir:)
    output, status = Open3.capture2e(*args, chdir: chdir)
    raise "command failed: #{args.join(' ')}\n#{output}" unless status.success?

    output
  end

  def build_main_repo
    FileUtils.mkdir_p(File.join(main_repo, 'app', 'models'))
    run!('git', 'init', '--quiet', '--initial-branch', 'main', '.', chdir: main_repo)
    run!('git', 'config', 'user.email', 'specs@example.test', chdir: main_repo)
    run!('git', 'config', 'user.name', 'Specs', chdir: main_repo)
    File.write(File.join(main_repo, 'app', 'models', 'post.rb'), "class Post\nend\n")
    run!('git', 'add', '.', chdir: main_repo)
    run!('git', 'commit', '--quiet', '-m', 'add post', chdir: main_repo)
  end

  def add_worktree
    run!('git', 'worktree', 'add', '--quiet', worktree, '-b', 'feature', chdir: main_repo)
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

      expect(logger).to have_received(:warn).with(/WOODS_GIT_DIR/).once
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

      expect(logger).to have_received(:warn).with(/WOODS_GIT_DIR/).once
    end

    it 'records provenance as unknown' do
      provenance = Woods::GitProvenance.new(root: worktree, env: {}).to_h

      expect(provenance).to eq(git_branch: 'unknown', git_sha: 'unknown')
    end
  end

  describe 'WOODS_GIT_DIR' do
    let(:canonical) { File.join(main_repo, '.git') }

    it 'wins over an unreachable commondir and restores the git keys' do
      break_commondir!
      stub_const('ENV', ENV.to_h.merge('WOODS_GIT_DIR' => canonical))

      unit = enrich!

      expect(unit.metadata[:git][:commit_count]).to eq(1)
      expect(unit.metadata[:git][:change_frequency]).to eq(:new)
    end

    it 'wins over a missing gitdir pointer' do
      break_gitdir_pointer!
      stub_const('ENV', ENV.to_h.merge('WOODS_GIT_DIR' => canonical))

      unit = enrich!

      expect(unit.metadata[:git][:last_author]).to eq('Specs')
    end

    it 'restores provenance for the manifest' do
      break_commondir!

      provenance = Woods::GitProvenance.new(root: worktree, env: { 'WOODS_GIT_DIR' => canonical }).to_h

      expect(provenance[:git_sha]).to match(/\A[0-9a-f]{40}\z/)
      expect(provenance[:git_branch]).to eq('main')
    end

    it 'is ignored when it is empty' do
      stub_const('ENV', ENV.to_h.merge('WOODS_GIT_DIR' => ''))

      unit = enrich!

      expect(unit.metadata[:git][:commit_count]).to eq(1)
    end
  end

  describe 'a healthy linked worktree' do
    it 'still enriches without any override' do
      unit = enrich!

      expect(unit.metadata[:git][:commit_count]).to eq(1)
    end

    it 'logs no warning' do
      enrich!

      expect(logger).not_to have_received(:warn)
    end
  end
end
