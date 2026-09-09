# frozen_string_literal: true

require 'spec_helper'
require 'woods/release/preparer'

RSpec.describe Woods::Release::Preparer do
  let(:date) { Date.new(2026, 9, 10) }

  def changelog_section(root, version)
    release_file(root, 'CHANGELOG.md')[/^## \[#{Regexp.escape(version)}\] - \d{4}-\d{2}-\d{2}\n(.*?)^## \[/m, 1]
  end

  def banner(root)
    Woods::Release::Notes.read_body(root, Woods::Release::Notes::FENCES.first)
  end

  describe 'alpha to the first beta' do
    it 'bumps the version, folds the changelog, and restates the documentation' do
      with_release_repository(version: '2.0.0.alpha') do |root|
        result = described_class.prepare(root: root, version: '2.0.0.beta1', date: date)

        expect(read_release_version(root)).to eq('2.0.0.beta1')
        expect(release_file(root, 'CHANGELOG.md')).to include('## [2.0.0.beta1] - 2026-09-10')
        expect(banner(root)).to include('2.0.0.beta1 is published as a prerelease')
        expect(release_file(root, 'CONTRIBUTING.md'))
          .to include('https://github.com/lost-in-the/woods/blob/v2.0.0.beta1/AGENTS.md')
        expect(result.changed_paths).to include(
          'lib/woods/version.rb', 'CHANGELOG.md', 'README.md', 'CONTRIBUTING.md', 'docs/UPGRADING_TO_2.md'
        )
      end
    end

    it 'folds one block per heading and leaves an empty Unreleased section behind' do
      with_release_repository(version: '2.0.0.alpha') do |root|
        described_class.prepare(root: root, version: '2.0.0.beta1', date: date)

        source = release_file(root, 'CHANGELOG.md')
        unreleased = source[/^## \[Unreleased\]\n(.*?)^## \[/m, 1]
        headings = changelog_section(root, '2.0.0.beta1').scan(/^### (.+)$/).flatten

        expect(unreleased).to eq("\n")
        expect(headings).to eq(headings.uniq)
        expect(headings).not_to be_empty
        expect(source).to include('## [1.6.1] - 2026-07-22')
      end
    end

    it 'prints the exact tag and dispatch commands and never runs them' do
      with_release_repository(version: '2.0.0.alpha') do |root|
        result = described_class.prepare(root: root, version: '2.0.0.beta1', date: date)

        expect(result.report).to include(
          'git tag v2.0.0.beta1 <merge-sha>',
          'git push origin v2.0.0.beta1',
          "-F 'client_payload[tag]=v2.0.0.beta1'"
        )
        expect(release_git(root, 'tag', '--list')).to eq('')
        expect(release_git(root, 'status', '--porcelain')).not_to eq('')
      end
    end
  end

  describe 'beta to the next beta' do
    it 'folds only the entries added since the previous beta' do
      with_release_repository(version: '2.0.0.alpha') do |root|
        described_class.prepare(root: root, version: '2.0.0.beta1', date: date)
        commit_release_repository_changes(root)
        add_unreleased_entry(root, 'Fixed', '- a fix found in beta1')

        described_class.prepare(root: root, version: '2.0.0.beta2', date: Date.new(2026, 9, 17))

        expect(read_release_version(root)).to eq('2.0.0.beta2')
        expect(changelog_section(root, '2.0.0.beta2')).to eq("\n### Fixed\n\n- a fix found in beta1\n\n")
        expect(release_file(root, 'CHANGELOG.md')).to include('## [2.0.0.beta1] - 2026-09-10')
        expect(banner(root)).to include('2.0.0.beta2 is published as a prerelease')
      end
    end
  end

  describe 'release candidate to the final release' do
    it 'drops every prerelease note and pins the documentation to the release tag' do
      with_release_repository(version: '2.0.0.rc1') do |root|
        described_class.prepare(root: root, version: '2.0.0', date: date)

        expect(read_release_version(root)).to eq('2.0.0')
        expect(release_file(root, 'CHANGELOG.md')).to include('## [2.0.0] - 2026-09-10')
        expect(banner(root)).to eq('')
        expect(Woods::Release::Notes.read_body(root, Woods::Release::Notes::FENCES.last)).to eq('')
        expect(release_file(root, 'CONTRIBUTING.md'))
          .to include('https://github.com/lost-in-the/woods/blob/v2.0.0/AGENTS.md')
      end
    end
  end

  describe 'reopening development' do
    it 'sets the next alpha and restores the alpha documentation state' do
      with_release_repository(version: '2.0.0.rc1') do |root|
        described_class.prepare(root: root, version: '2.0.0', date: date)
        commit_release_repository_changes(root)

        result = described_class.reopen(root: root, version: '2.1.0.alpha')

        expect(read_release_version(root)).to eq('2.1.0.alpha')
        expect(banner(root)).to include(
          '`main` documents 2.1.0, which is not released yet',
          '> | Latest published gem | **2.0.0** |'
        )
        expect(release_file(root, 'CONTRIBUTING.md'))
          .to include('https://github.com/lost-in-the/woods/blob/main/AGENTS.md')
        expect(release_file(root, 'CHANGELOG.md')).to include('## [2.0.0] - 2026-09-10')
        expect(result.report).to include('2.1.0.alpha')
      end
    end

    it 'leaves the changelog alone' do
      with_release_repository(version: '2.0.0.rc1') do |root|
        described_class.prepare(root: root, version: '2.0.0', date: date)
        commit_release_repository_changes(root)
        before = release_file(root, 'CHANGELOG.md')

        described_class.reopen(root: root, version: '2.1.0.alpha')

        expect(release_file(root, 'CHANGELOG.md')).to eq(before)
      end
    end
  end

  describe 'refusals' do
    it 'refuses to prepare a release on a dirty working tree' do
      with_release_repository(version: '2.0.0.alpha') do |root|
        File.write(File.join(root, 'README.md'), "#{release_file(root, 'README.md')}\nstray edit\n")

        expect { described_class.prepare(root: root, version: '2.0.0.beta1', date: date) }
          .to raise_error(described_class::DirtyWorkingTree, /README\.md/)
        expect(read_release_version(root)).to eq('2.0.0.alpha')
      end
    end

    it 'refuses to reopen development on a dirty working tree' do
      with_release_repository(version: '2.0.0') do |root|
        File.write(File.join(root, 'README.md'), "#{release_file(root, 'README.md')}\nstray edit\n")

        expect { described_class.reopen(root: root, version: '2.1.0.alpha') }
          .to raise_error(described_class::DirtyWorkingTree)
      end
    end

    it 'refuses a version that moves backwards' do
      with_release_repository(version: '2.0.0.beta2') do |root|
        expect { described_class.prepare(root: root, version: '2.0.0.beta1', date: date) }
          .to raise_error(Woods::Release::VersionState::InvalidTransition, /does not come after/)
        expect(read_release_version(root)).to eq('2.0.0.beta2')
      end
    end

    it 'refuses a version whose base does not match the line main is developing' do
      with_release_repository(version: '2.0.0.alpha') do |root|
        expect { described_class.prepare(root: root, version: '2.1.0.beta1', date: date) }
          .to raise_error(Woods::Release::VersionState::InvalidTransition, /main is developing 2\.0\.0/)
        expect(release_file(root, 'CHANGELOG.md')).not_to include('## [2.1.0.beta1]')
      end
    end

    it 'refuses a version that is not a Woods version at all' do
      with_release_repository(version: '2.0.0.alpha') do |root|
        expect { described_class.prepare(root: root, version: 'v2.0.0', date: date) }
          .to raise_error(Woods::Release::VersionState::InvalidVersion)
      end
    end
  end
end
