# frozen_string_literal: true

require 'spec_helper'
require 'woods/release/preparer'

RSpec.describe 'changelog entry files' do
  def fragment(root, name, body)
    FileUtils.mkdir_p(File.join(root, 'changelog'))
    File.write(File.join(root, 'changelog', name), body)
  end

  def prepare(root)
    Woods::Release::Preparer.prepare(root: root, version: '2.0.0.beta1', date: Date.new(2026, 9, 17))
  end

  it 'folds sorted entries after inline notes, reports removals, and keeps unrelated files' do
    changelog = "# Changelog\n\n## [Unreleased]\n\n### Fixed\n\n- inline fix\n"
    with_release_repository(changelog: changelog) do |root|
      fragment(root, 'fixed_zebra.md', "- last fix\n")
      fragment(root, 'fixed_alpha.md', "- first fix\n  with continuation\n")
      fragment(root, 'added_feature.md', "- new feature\n")
      fragment(root, 'README.txt', 'keep this')
      commit_release_repository_changes(root)

      result = prepare(root)

      expect(release_file(root, 'CHANGELOG.md')).to include(
        "### Fixed\n\n- inline fix\n- first fix\n  with continuation\n- last fix\n\n### Added\n\n- new feature"
      )
      expect(result.changed_paths).to include('changelog/fixed_alpha.md', 'changelog/added_feature.md')
      expect(Dir.children(File.join(root, 'changelog'))).to eq(['README.txt'])
    end
  end

  it 'can prepare a prerelease from fragments alone' do
    with_release_repository(changelog: "# Changelog\n\n## [Unreleased]\n") do |root|
      fragment(root, 'fixed_only.md', '- a fix')
      commit_release_repository_changes(root)
      expect { prepare(root) }.not_to raise_error
      expect(release_file(root, 'CHANGELOG.md')).to include("### Fixed\n\n- a fix")
    end
  end

  {
    'unknown_entry.md' => '- a fix',
    'fixed_.md' => '- a fix',
    'fixed_empty.md' => "\n",
    'fixed_encoding.md' => "- invalid \xFF".b,
    'fixed_heading.md' => "- a fix\n## [9.0.0] - 2026-01-01\n",
    'fixed_subheading.md' => "### Added\n- a fix\n",
    'fixed_setext.md' => "Title\n-----\n- a fix\n",
    'fixed_setext-level-one.md' => "Title\n=====\n- a fix\n",
    'fixed_setext-crlf.md' => "Title\r\n-----\r\n- a fix\r\n"
  }.each do |name, body|
    it "refuses #{name} before changing any files or consuming valid entries" do
      with_release_repository do |root|
        fragment(root, 'fixed_valid.md', '- valid entry')
        fragment(root, name, body)
        commit_release_repository_changes(root)
        before = release_repository_digest(root)
        expect { prepare(root) }.to raise_error(Woods::Release::Error, /changelog/)
        expect(release_repository_digest(root)).to eq(before)
        expect(release_git(root, 'status', '--porcelain')).to eq('')
      end
    end
  end

  it 'accepts fragment-only development after a beta and folds it into the next beta' do
    changelog = "# Changelog\n\n## [Unreleased]\n\n## [2.0.0.beta1] - 2026-09-10\n"
    with_release_repository(version: '2.0.0.beta1', changelog: changelog) do |root|
      fragment(root, 'fixed_beta-feedback.md', '- a beta fix')
      commit_release_repository_changes(root)
      expect(Woods::Release::Fragments.read(root).keys).to eq(['changelog/fixed_beta-feedback.md'])

      Woods::Release::Preparer.prepare(root: root, version: '2.0.0.beta2', date: Date.new(2026, 9, 17))

      expect(release_file(root, 'CHANGELOG.md'))
        .to include("## [2.0.0.beta2] - 2026-09-17\n\n### Fixed\n\n- a beta fix")
      expect(Woods::Release::Fragments.read(root)).to be_empty
    end
  end

  it 'maps a multiword type to the existing Upgrade Notes heading' do
    with_release_repository do |root|
      fragment(root, 'upgrade-notes_compatibility.md', '- a compatibility note')
      commit_release_repository_changes(root)
      prepare(root)
      expect(release_file(root, 'CHANGELOG.md')).to include("### Upgrade Notes\n\n- a compatibility note")
    end
  end

  it 'leaves valid fragments untouched when a later documentation validation refuses' do
    with_release_repository do |root|
      fragment(root, 'fixed_valid.md', '- valid entry')
      path = File.join(root, 'README.md')
      File.write(path, release_file(root, 'README.md').sub('<!-- release-state:version-banner -->', ''))
      commit_release_repository_changes(root)
      before = release_repository_digest(root)
      expect { prepare(root) }.to raise_error(Woods::Release::Notes::MissingFence)
      expect(release_repository_digest(root)).to eq(before)
    end
  end

  %i[directory entry].each do |kind|
    it "refuses a symlinked #{kind} without changing its target" do
      with_release_repository do |root|
        Dir.mktmpdir do |outside|
          File.write(File.join(outside, 'fixed_link.md'), '- external entry')
          if kind == :directory
            File.symlink(outside, File.join(root, 'changelog'))
          else
            FileUtils.mkdir_p(File.join(root, 'changelog'))
            File.symlink(File.join(outside, 'fixed_link.md'), File.join(root, 'changelog/fixed_link.md'))
          end
          commit_release_repository_changes(root)
          before = release_repository_digest(root)
          expect { prepare(root) }.to raise_error(Woods::Release::Error, /changelog/)
          expect(release_repository_digest(root)).to eq(before)
          expect(File.read(File.join(outside, 'fixed_link.md'))).to eq('- external entry')
          expect(release_git(root, 'status', '--porcelain')).to eq('')
        end
      end
    end
  end

  it 'refuses a directory with an entry filename without recursively deleting it' do
    with_release_repository do |root|
      FileUtils.mkdir_p(File.join(root, 'changelog/fixed_directory.md'))
      File.write(File.join(root, 'changelog/fixed_directory.md/keep'), 'keep')
      commit_release_repository_changes(root)
      before = release_repository_digest(root)
      expect { prepare(root) }.to raise_error(Woods::Release::Error, /changelog/)
      expect(release_repository_digest(root)).to eq(before)
    end
  end
end
