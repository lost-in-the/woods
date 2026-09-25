# frozen_string_literal: true

require 'spec_helper'
require 'fileutils'
require 'open3'
require 'tmpdir'
require 'woods/release/preparer'

RSpec.describe Woods::Release::Preparer do
  around do |example|
    Dir.mktmpdir('woods-maintenance-task') do |root|
      @root = root
      FileUtils.mkdir_p(File.join(root, 'lib/woods'))
      File.write(File.join(root, 'lib/woods/version.rb'), "module Woods\n  VERSION = '1.6.3'\nend\n")
      banner = Woods::Release::Notes.banner(Woods::Release::VersionState.parse('1.6.3'))
      File.write(File.join(root, 'README.md'), "# Woods\n\n#{banner}\nLegacy guide.\n")
      File.write(File.join(root, 'CHANGELOG.md'), <<~MARKDOWN)
        # Changelog

        ## [Unreleased]

        ### Fixed

        - Credential refresh.

        ## [1.6.3] - 2026-07-22

        ### Fixed

        - Previous fix.
      MARKDOWN
      git('init', '-q')
      git('config', 'user.name', 'Maintenance Fixture')
      git('config', 'user.email', 'fixture@example.invalid')
      commit
      example.run
    end
  end

  def git(*args)
    output, status = Open3.capture2e('git', *args, chdir: @root)
    raise output unless status.success?

    output
  end

  def commit
    git('add', '.')
    git('commit', '-qm', 'Fixture')
  end

  def bytes
    Dir.glob(File.join(@root, '**', '*')).select { |path| File.file?(path) }
       .to_h { |path| [path.delete_prefix("#{@root}/"), File.binread(path)] }
  end

  def reopen
    described_class.reopen(root: @root, version: '1.6.4.alpha')
    commit
  end

  def prepare
    described_class.prepare(root: @root, version: '1.6.4', date: Date.new(2026, 9, 21))
  end

  it 'runs the only approved cycle without committing, tagging, or claiming publication' do
    before_log = git('rev-parse', 'HEAD')
    result = described_class.reopen(root: @root, version: '1.6.4.alpha')
    expect(result.changed_paths).to contain_exactly('lib/woods/version.rb', 'README.md')
    expect(git('rev-parse', 'HEAD')).to eq(before_log)
    expect(File.read(File.join(@root, 'README.md'))).to include('never tag or publish this alpha')
    commit
    before_log = git('rev-parse', 'HEAD')
    result = prepare

    expect(described_class.current_state(@root).to_s).to eq('1.6.4')
    expect(File.read(File.join(@root, 'CHANGELOG.md'))).to include('## [1.6.4] - 2026-09-21')
    expect(File.read(File.join(@root, 'README.md'))).to include('prepared maintenance candidate')
    expect(Woods::Release::Notes.mismatches(root: @root, version: '1.6.4')).to be_empty
    expect(result.report).to include('release/1.6.4', 'Nothing has been committed', 'git tag v1.6.4 <merge-sha>')
    expect(result.report.index('pinning approved_sha')).to be < result.report.index('git tag v1.6.4')
    expect(git('rev-parse', 'HEAD')).to eq(before_log)
    expect(git('tag', '--list')).to be_empty
  end

  it 'executes both public rake commands with the same no-publish contract' do
    source = File.expand_path('../..', __dir__)
    FileUtils.cp_r(File.join(source, 'lib/woods/release'), File.join(@root, 'lib/woods'))
    FileUtils.cp(File.join(source, 'lib/woods/release.rb'), File.join(@root, 'lib/woods'))
    FileUtils.mkdir_p(File.join(@root, 'lib/tasks'))
    FileUtils.cp(File.join(source, 'lib/tasks/release.rake'), File.join(@root, 'lib/tasks'))
    File.write(File.join(@root, 'Rakefile'), "load File.expand_path('lib/tasks/release.rake', __dir__)\n")
    commit
    %w[release:reopen[1.6.4.alpha] release:prepare[1.6.4]].each do |task|
      output, status = Open3.capture2e(Gem.ruby, '-S', 'rake', task, chdir: @root)
      expect(status).to be_success, output
      expect(output).to include('Nothing has been committed')
      commit
    end
    expect(described_class.current_state(@root).to_s).to eq('1.6.4')
    expect(git('tag', '--list')).to be_empty
  end

  it 'refuses direct preparation from a final release without writing' do
    prior = bytes
    expect { prepare }.to raise_error(Woods::Release::VersionState::InvalidTransition)
    expect(bytes).to eq(prior)
  end

  it 'refuses another line, a backwards version, and a beta target without writing' do
    prior = bytes
    %w[1.7.0.alpha 1.6.3.alpha 1.6.5.alpha 2.0.0.alpha].each do |version|
      expect { described_class.reopen(root: @root, version: version) }
        .to raise_error(Woods::Release::VersionState::InvalidTransition)
    end
    expect(bytes).to eq(prior)
    reopen
    prior = bytes
    expect { described_class.prepare(root: @root, version: '1.6.4.beta1') }
      .to raise_error(Woods::Release::VersionState::InvalidTransition)
    expect(bytes).to eq(prior)
  end

  it 'refuses tracked or untracked dirty work before any transition writes' do
    File.write(File.join(@root, 'untracked.txt'), 'keep')
    prior = bytes
    expect { described_class.reopen(root: @root, version: '1.6.4.alpha') }
      .to raise_error(described_class::DirtyWorkingTree)
    expect(bytes).to eq(prior)
    File.unlink(File.join(@root, 'untracked.txt'))
    reopen
    File.write(File.join(@root, 'README.md'), 'keep modified')
    prior = bytes
    expect { prepare }.to raise_error(described_class::DirtyWorkingTree)
    expect(bytes).to eq(prior)
  end

  it 'refuses invalid changelog and missing fences before changing VERSION' do
    reopen
    File.write(File.join(@root, 'CHANGELOG.md'), "## [Unreleased]\n\nunclassified note\n")
    commit
    prior = bytes
    expect { prepare }.to raise_error(Woods::Release::Changelog::UnclassifiedEntries)
    expect(bytes).to eq(prior)
  end

  it 'refuses missing, duplicate, or unregistered fences without changing any file' do
    reopen
    original = File.read(File.join(@root, 'README.md'))
    ['# Woods', original + original, "#{original}<!-- release-state:unknown -->\n"].each do |source|
      File.write(File.join(@root, 'README.md'), source)
      commit
      prior = bytes
      expect { prepare }.to raise_error(Woods::Release::Notes::MissingFence)
      expect(bytes).to eq(prior)
    end
  end

  it 'refuses missing or malformed existing markers before writing' do
    opening = Woods::Release::Notes::OPEN
    closing = Woods::Release::Notes::CLOSE
    ["# Woods\n", "# Woods\n#{opening}\nold\n#{closing}", "# Woods\n<!-- release-state:unfinished\n"].each do |source|
      File.write(File.join(@root, 'README.md'), source)
      commit
      prior = bytes
      expect { described_class.reopen(root: @root, version: '1.6.4.alpha') }
        .to raise_error(Woods::Release::Notes::MissingFence)
      expect(bytes).to eq(prior)
    end
  end

  it 'folds classified fragments and deletes only consumed files' do
    reopen
    FileUtils.mkdir_p(File.join(@root, 'changelog'))
    File.write(File.join(@root, 'changelog/security_refresh.md'), '- Safe refresh.\n')
    File.write(File.join(@root, 'changelog/README.txt'), 'keep')
    commit
    prepare
    expect(File.read(File.join(@root, 'CHANGELOG.md'))).to include('### Security', 'Safe refresh.')
    expect(File).not_to exist(File.join(@root, 'changelog/security_refresh.md'))
    expect(File.read(File.join(@root, 'changelog/README.txt'))).to eq('keep')
  end

  it 'refuses a symlink fragment before changing or deleting anything' do
    reopen
    FileUtils.mkdir_p(File.join(@root, 'changelog'))
    File.symlink('../README.md', File.join(@root, 'changelog/fixed_link.md'))
    commit
    prior = bytes
    expect { prepare }.to raise_error(Woods::Release::Fragments::InvalidEntry)
    expect(bytes).to eq(prior)
    expect(File).to be_symlink(File.join(@root, 'changelog/fixed_link.md'))
  end
end
