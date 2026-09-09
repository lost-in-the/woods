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
end
