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
  # registry both quote the marker as a plain string.
  def marked_documents(marker)
    stdout, stderr, status = Open3.capture3(
      'git', 'grep', '-l', '--fixed-strings', marker, '--', '*.md', chdir: root
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
end
