# frozen_string_literal: true

require 'spec_helper'
require 'woods/release/notes'

RSpec.describe Woods::Release::Notes do
  def banner(root)
    described_class.read_body(root, described_class::FENCES.first)
  end

  def upgrade_note(root)
    described_class.read_body(root, described_class::FENCES.last)
  end

  it 'leaves the checked-in fences alone when they already match the version' do
    with_release_repository(version: '2.0.0.alpha', commit: false) do |root|
      expect(described_class.apply!(root: root, version: '2.0.0.alpha')).to be_empty
      expect(described_class.mismatches(root: root, version: '2.0.0.alpha')).to be_empty
    end
  end

  it 'reports a mismatch when the fences disagree with the version' do
    with_release_repository(version: '2.0.0.alpha', commit: false) do |root|
      expect(described_class.mismatches(root: root, version: '2.0.0.beta1')).to contain_exactly(
        'README.md: release-state:version-banner does not match the beta state of 2.0.0.beta1',
        'CONTRIBUTING.md: release-state:contributing-intro links do not point at v2.0.0.beta1',
        'CONTRIBUTING.md: release-state:contributing-architecture links do not point at v2.0.0.beta1',
        'docs/UPGRADING_TO_2.md: release-state:upgrade-availability does not match the beta state of 2.0.0.beta1'
      )
    end
  end

  it 'rewrites the fences into the prerelease state and pins every repository link to the tag' do
    with_release_repository(version: '2.0.0.alpha', commit: false) do |root|
      described_class.apply!(root: root, version: '2.0.0.beta1')

      expect(banner(root)).to include(
        '> ### Version: 2.0.0.beta1 is published as a prerelease; `main` documents 2.0.0',
        '> | Latest prerelease | **2.0.0.beta1** | [the v2.0.0.beta1 tag]',
        '> | Latest published gem | **1.6.1** |',
        'Install it explicitly with `gem "woods", "2.0.0.beta1"`'
      )
      expect(upgrade_note(root)).to include('RubyGems lists 2.0.0.beta1 as a prerelease')
      expect(release_file(root, 'CONTRIBUTING.md')).to include(
        'https://github.com/lost-in-the/woods/blob/v2.0.0.beta1/AGENTS.md',
        'https://github.com/lost-in-the/woods/blob/v2.0.0.beta1/CLAUDE.md'
      )
      expect(described_class.mismatches(root: root, version: '2.0.0.beta1')).to be_empty
    end
  end

  it 'empties the note fences at a final release and keeps the markers for the next cycle' do
    with_release_repository(version: '2.0.0.alpha', commit: false) do |root|
      described_class.apply!(root: root, version: '2.0.0')

      expect(banner(root)).to eq('')
      expect(upgrade_note(root)).to eq('')
      expect(release_file(root, 'README.md')).to include(
        "<!-- release-state:version-banner -->\n<!-- release-state:end -->"
      )
      expect(release_file(root, 'CONTRIBUTING.md'))
        .to include('https://github.com/lost-in-the/woods/blob/v2.0.0/AGENTS.md')
      expect(described_class.mismatches(root: root, version: '2.0.0')).to be_empty
    end
  end

  it 'restores the alpha state when development reopens' do
    with_release_repository(version: '2.0.0.alpha', commit: false) do |root|
      original = described_class::FENCES.to_h { |fence| [fence.fetch(:id), described_class.read_body(root, fence)] }
      described_class.apply!(root: root, version: '2.0.0')
      described_class.apply!(root: root, version: '2.0.0.alpha')

      restored = described_class::FENCES.to_h { |fence| [fence.fetch(:id), described_class.read_body(root, fence)] }
      expect(restored).to eq(original)
    end
  end

  it 'names the newest stable changelog release as the published gem, never a prerelease' do
    changelog = <<~MARKDOWN
      ## [Unreleased]

      ## [2.0.0.beta1] - 2026-09-10

      ## [1.6.1] - 2026-07-22
    MARKDOWN

    with_release_repository(version: '2.0.0.beta1', changelog: changelog, commit: false) do |root|
      described_class.apply!(root: root, version: '2.0.0.beta1')

      expect(banner(root)).to include('> | Latest published gem | **1.6.1** |')
      expect(banner(root)).not_to include('Latest published gem | **2.0.0.beta1**')
    end
  end

  it 'raises when a registered fence has been removed from a document' do
    with_release_repository(version: '2.0.0.alpha', commit: false) do |root|
      path = File.join(root, 'README.md')
      File.write(path, release_file(root, 'README.md').sub('<!-- release-state:version-banner -->', ''))

      expect { described_class.apply!(root: root, version: '2.0.0') }
        .to raise_error(described_class::MissingFence, /README\.md: no release-state:version-banner fence/)
    end
  end
end
