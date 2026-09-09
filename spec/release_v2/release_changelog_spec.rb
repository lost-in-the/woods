# frozen_string_literal: true

require 'spec_helper'
require 'woods/release/changelog'

RSpec.describe Woods::Release::Changelog do
  let(:source) do
    <<~MARKDOWN
      # Changelog

      All notable changes to this project will be documented in this file.

      ## [Unreleased]

      ### Added

      - first added entry

      ### Performance

      - a performance entry

      ### Added

      - second added entry

      ## [1.6.1] - 2026-07-22

      ### Fixed

      - an old fix
    MARKDOWN
  end

  it 'folds Unreleased into a dated heading with one block per heading, in first-appearance order' do
    folded = described_class.fold(source, version: '2.0.0.beta1', date: Date.new(2026, 9, 10))

    expect(folded).to eq(<<~MARKDOWN)
      # Changelog

      All notable changes to this project will be documented in this file.

      ## [Unreleased]

      ## [2.0.0.beta1] - 2026-09-10

      ### Added

      - first added entry

      - second added entry

      ### Performance

      - a performance entry

      ## [1.6.1] - 2026-07-22

      ### Fixed

      - an old fix
    MARKDOWN
  end

  it 'leaves an empty Unreleased section behind for the next cycle' do
    folded = described_class.fold(source, version: '2.0.0.beta1', date: Date.new(2026, 9, 10))
    unreleased = folded[/^## \[Unreleased\]\n(.*?)^## \[/m, 1]

    expect(unreleased.strip).to eq('')
  end

  it 'folds the real repository changelog into exactly one block per heading' do
    real = File.read(File.expand_path('../../CHANGELOG.md', __dir__), encoding: Encoding::UTF_8)
    folded = described_class.fold(real, version: '2.0.0.beta1', date: Date.new(2026, 9, 10))
    section = folded[/^## \[2\.0\.0\.beta1\] - 2026-09-10\n(.*?)^## \[1\.6\.1\]/m, 1]
    headings = section.scan(/^### (.+)$/).flatten

    expect(headings).to eq(headings.uniq)
    expect(headings).to include('Added', 'Performance', 'Documentation')
    expect(folded).to include('## [1.6.1] - 2026-07-22')
  end

  it 'refuses to fold an empty Unreleased section' do
    empty = source.sub(/^## \[Unreleased\]\n.*?(?=^## \[1\.6\.1\])/m, "## [Unreleased]\n\n")

    expect { described_class.fold(empty, version: '2.0.0', date: Date.new(2026, 9, 10)) }
      .to raise_error(described_class::EmptyUnreleasedSection, /nothing to release/)
  end

  it 'refuses to fold entries that sit outside a heading block' do
    stray = source.sub("## [Unreleased]\n\n### Added", "## [Unreleased]\n\n- a stray entry\n\n### Added")

    expect { described_class.fold(stray, version: '2.0.0', date: Date.new(2026, 9, 10)) }
      .to raise_error(described_class::UnclassifiedEntries, /a stray entry/)
  end

  it 'refuses to fold a changelog with no Unreleased section' do
    expect { described_class.fold("# Changelog\n", version: '2.0.0', date: Date.new(2026, 9, 10)) }
      .to raise_error(described_class::MissingUnreleasedSection)
  end

  it 'refuses to fold a version that already has a dated heading' do
    expect { described_class.fold(source, version: '1.6.1', date: Date.new(2026, 9, 10)) }
      .to raise_error(described_class::DuplicateRelease, /1\.6\.1/)
  end

  describe 'folding a final release over its own prereleases' do
    let(:with_prereleases) do
      <<~MARKDOWN
        # Changelog

        ## [Unreleased]

        ### Fixed

        - a fix found after rc1

        ### Added

        - a late addition

        ## [2.0.0.rc1] - 2026-09-05

        ### Added

        - an rc1 addition

        ### Performance

        - an rc1 speedup

        ## [2.0.0.beta1] - 2026-09-01

        ### Added

        - a beta1 addition

        ## [1.6.1] - 2026-07-22

        ### Fixed

        - an old fix
      MARKDOWN
    end

    it 'merges every prerelease section of the same base into the release, oldest entries first' do
      folded = described_class.fold(with_prereleases, version: '2.0.0', date: Date.new(2026, 9, 20))
      section = folded[/^## \[2\.0\.0\] - 2026-09-20\n(.*?)^## \[1\.6\.1\]/m, 1]

      expect(section).to eq(<<~MARKDOWN)

        ### Added

        - a beta1 addition

        - an rc1 addition

        - a late addition

        ### Performance

        - an rc1 speedup

        ### Fixed

        - a fix found after rc1

      MARKDOWN
    end

    it 'removes the prerelease headings so the shipped notes live in one place' do
      folded = described_class.fold(with_prereleases, version: '2.0.0', date: Date.new(2026, 9, 20))

      expect(folded).not_to include('## [2.0.0.rc1]')
      expect(folded).not_to include('## [2.0.0.beta1]')
      expect(folded).to include('## [1.6.1] - 2026-07-22')
      expect(folded[/^## \[Unreleased\]\n(.*?)^## \[/m, 1]).to eq("\n")
    end

    it 'releases a final version whose Unreleased section is empty from its prereleases alone' do
      empty = with_prereleases.sub(/^## \[Unreleased\]\n.*?(?=^## \[2\.0\.0\.rc1\])/m, "## [Unreleased]\n\n")
      folded = described_class.fold(empty, version: '2.0.0', date: Date.new(2026, 9, 20))
      section = folded[/^## \[2\.0\.0\] - 2026-09-20\n(.*?)^## \[1\.6\.1\]/m, 1]

      expect(section.scan(/^### (.+)$/).flatten).to eq(%w[Added Performance])
      expect(section).to include('- a beta1 addition', '- an rc1 addition', '- an rc1 speedup')
    end

    it 'leaves a prerelease of another base alone' do
      folded = described_class.fold(with_prereleases.sub('2.0.0.beta1', '1.7.0.beta1'),
                                    version: '2.0.0', date: Date.new(2026, 9, 20))

      expect(folded).to include('## [1.7.0.beta1] - 2026-09-01')
      expect(folded).not_to include('## [2.0.0.rc1]')
    end

    it 'refuses a prerelease whose Unreleased section is empty, even with an earlier prerelease section' do
      empty = with_prereleases.sub(/^## \[Unreleased\]\n.*?(?=^## \[2\.0\.0\.rc1\])/m, "## [Unreleased]\n\n")

      expect { described_class.fold(empty, version: '2.0.0.rc2', date: Date.new(2026, 9, 20)) }
        .to raise_error(described_class::EmptyUnreleasedSection, /nothing to release/)
    end

    it 'refuses a final release with neither Unreleased entries nor a prerelease section' do
      bare = "# Changelog\n\n## [Unreleased]\n\n## [1.6.1] - 2026-07-22\n"

      expect { described_class.fold(bare, version: '2.0.0', date: Date.new(2026, 9, 20)) }
        .to raise_error(described_class::EmptyUnreleasedSection, /nothing to release/)
    end
  end

  it 'dates a fold in UTC by default' do
    folded = described_class.fold(source, version: '2.0.0.beta1')

    expect(folded).to include("## [2.0.0.beta1] - #{Time.now.utc.strftime('%Y-%m-%d')}")
  end
end
