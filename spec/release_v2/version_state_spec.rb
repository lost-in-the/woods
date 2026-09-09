# frozen_string_literal: true

require 'spec_helper'
require 'json'
require 'open3'
require 'woods/release/notes'
require 'woods/release/version_state'

# The enforcement for the prerelease flow on `main`. Every commit on this
# branch has to satisfy it, so a release that half-lands (a version bump
# without the changelog fold, a fence left in the previous state, a plugin
# version quietly wired to the gem version) fails here rather than at tag time.
RSpec.describe 'release version state' do
  let(:root) { File.expand_path('../..', __dir__) }
  let(:version) { Woods::VERSION }
  let(:state) { Woods::Release::VersionState.parse(version) }
  let(:changelog) { File.read(File.join(root, 'CHANGELOG.md'), encoding: Encoding::UTF_8) }

  # Markdown only: the fences live in documentation, and the specs and the Notes
  # registry both quote the marker as a plain string. The release fixture under
  # spec/fixtures carries the same fences on purpose, so the transition specs
  # can rewrite them without touching this checkout; it is not repository
  # documentation and is not what this enforcement is about.
  def marked_documents(marker)
    stdout, stderr, status = Open3.capture3(
      'git', 'grep', '-l', '--fixed-strings', marker, '--', '*.md', ':(exclude)spec/fixtures/**', chdir: root
    )
    raise stderr unless status.success? || status.exitstatus == 1

    stdout.split("\n")
  end

  it 'carries either the alpha development marker or a dated changelog heading' do
    dated_heading = /^## \[#{Regexp.escape(version)}\] - \d{4}-\d{2}-\d{2}$/
    explanation = "Woods::VERSION is #{version.inspect}, which is not an alpha development marker, and " \
                  "CHANGELOG.md has no dated \"## [#{version}]\" heading. `main` must carry X.Y.Z.alpha " \
                  'between releases; a released version only lands through release:prepare, which folds ' \
                  'the changelog.'

    expect(state.alpha? || changelog.match?(dated_heading)).to be(true), explanation
  end

  it 'always keeps an Unreleased section for the next release to collect into' do
    expect(changelog).to include('## [Unreleased]')
  end

  it 'keeps every release-state fence in the state VERSION declares' do
    expect(Woods::Release::Notes.mismatches(root: root, version: version)).to be_empty
  end

  it 'registers every release-state fence in the repository' do
    documented = Woods::Release::Notes::FENCES.map { |fence| fence.fetch(:path) }.uniq.sort
    marked = marked_documents("<!-- #{Woods::Release::Notes::MARKER}:")

    expect(marked.sort).to eq(documented)
  end

  it 'keeps the distributed plugin version independent of the gem version' do
    manifest_path = File.join(root, 'plugin/.claude-plugin/plugin.json')
    source = File.read(manifest_path, encoding: Encoding::UTF_8)
    plugin_version = JSON.parse(source).fetch('version')

    expect(plugin_version).to match(/\A\d+\.\d+\.\d+\z/)
    expect(plugin_version).not_to eq(version)
    expect(source).not_to include('Woods::VERSION')
  end

  # A version claim outside a fence is a claim nothing rewrites, so it survives
  # the release that makes it false. Only the banner may name a version here.
  it 'keeps every version claim in README.md inside a release-state fence' do
    outside = Woods::Release::Notes.source_outside_fences(root, 'README.md')
    claims = outside.scan(/(?<![\d.])v?\d+\.\d+\.\d+/)

    expect(claims).to be_empty
  end

  # Two fences with the same id in one document would let `apply!` rewrite the
  # first and silently leave the second in the previous state.
  it 'declares each release-state fence id exactly once across the repository' do
    ids = marked_documents("<!-- #{Woods::Release::Notes::MARKER}:").flat_map do |path|
      File.read(File.join(root, path), encoding: Encoding::UTF_8)
          .scan(/<!-- #{Woods::Release::Notes::MARKER}:([a-z][a-z-]*) -->/).flatten
    end
    duplicated = ids.reject { |id| id == 'end' }.tally.select { |_id, count| count > 1 }

    expect(duplicated).to be_empty
  end
end
