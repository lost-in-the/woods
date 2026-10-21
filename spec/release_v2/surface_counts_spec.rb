# frozen_string_literal: true

require 'spec_helper'
require 'json'
require 'woods/release_v2/surface_counts'

RSpec.describe Woods::ReleaseV2::SurfaceCounts do
  let(:counts) { described_class.counts }

  it 'rewrites every documented count claim from the code-derived counts, idempotently' do
    source = "Woods ships **1 extractor classes** producing **2 distinct unit types**. All 3 extractors run.\n" \
             "│ 4 types │ one of the 5 types in `TYPE_TO_EXTRACTOR_KEY`; the 29-tool index server\n"
    rewritten = described_class.rewrite(source)

    extractors = counts.fetch('extractor_registrations')
    types = counts.fetch('unit_types')
    expect(rewritten).to eq(
      "Woods ships **#{extractors} extractor classes** producing **#{types} distinct unit types**. " \
      "All #{extractors} extractors run.\n" \
      "│ #{types} types │ one of the #{types} types in `TYPE_TO_EXTRACTOR_KEY`; " \
      "the #{counts.fetch('index_mcp_tools')}-tool index server\n"
    )
    expect(described_class.rewrite(rewritten)).to eq(rewritten)
  end

  it 'leaves prose numbers that are not surface claims alone' do
    source = "two extractors claim this path; 2 resources, 2 templates; 10 retries\n"
    expect(described_class.rewrite(source)).to eq(source)
  end

  it 'covers the public guides and the context7 manifest' do
    targets = described_class.targets.map { |path| path.relative_path_from(described_class::ROOT).to_s }
    expect(targets).to include('README.md', 'context7.json', 'docs/EXTRACTOR_REFERENCE.md', 'docs/INTERNALS.md',
                               'docs/FAQ.md')
    expect(targets.grep(%r{docs/design/})).to eq([])
  end

  it 'finds no drift in the checked-in documentation' do
    expect(described_class.drift).to eq([]), 'run script/sync-surface-counts and commit the result'
  end

  it 'derives unit_types from the extractor type map' do
    require 'woods/extractor'
    expect(counts.fetch('unit_types')).to eq(Woods::Extractor::TYPE_TO_EXTRACTOR_KEY.count)
  end
end
