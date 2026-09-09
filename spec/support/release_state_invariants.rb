# frozen_string_literal: true

require 'woods/release/changelog'
require 'woods/release/notes'
require 'woods/release/preparer'

# The claims that must hold of any tree the release flow produces, stated so
# they read the tree's own VERSION rather than assuming one state. Include with
# a `release_root` naming the tree to check.
RSpec.shared_examples 'a coherent release state' do
  let(:release_state) { Woods::Release::Preparer.current_state(release_root) }
  let(:release_changelog) { File.read(File.join(release_root, 'CHANGELOG.md'), encoding: Encoding::UTF_8) }
  let(:release_unreleased) { release_changelog[/^## \[Unreleased\]\n(.*?)^## \[/m, 1] }

  it 'keeps every release-state fence in the state VERSION declares' do
    expect(Woods::Release::Notes.mismatches(root: release_root, version: release_state.to_s)).to be_empty
  end

  it 'keeps an Unreleased section for the next cycle to collect into' do
    expect(release_changelog).to include('## [Unreleased]')
  end

  it 'carries a dated changelog heading once the version is releasable, and none while it is an alpha' do
    if release_state.alpha?
      expect(release_changelog).not_to match(/^## \[#{Regexp.escape(release_state.base)}[^\]]*\] - /)
    else
      expect(release_changelog).to match(/^## \[#{Regexp.escape(release_state.to_s)}\] - \d{4}-\d{2}-\d{2}$/)
    end
  end

  it 'empties Unreleased at a release and leaves it collecting during development' do
    if release_state.alpha?
      expect { Woods::Release::Changelog.fold(release_changelog, version: "#{release_state.base}.beta1") }
        .not_to raise_error
    else
      expect(release_unreleased.to_s.strip).to eq('')
    end
  end

  it 'points the documentation links at the ref this state names' do
    contributing = File.read(File.join(release_root, 'CONTRIBUTING.md'), encoding: Encoding::UTF_8)
    prefix = "#{Woods::Release::Notes::REPOSITORY_URL}/blob/"

    expect(contributing.scan(%r{#{Regexp.escape(prefix)}([^/\s)]+)}).flatten.uniq)
      .to eq([release_state.release_ref])
  end
end
