# frozen_string_literal: true

require 'spec_helper'
require 'woods/extractors/lib_extractor'
require 'woods/source_contributors'
require 'woods/retrieval/source_evidence'
require 'woods/retrieval/scope'

RSpec.describe Woods::SourceContributors do
  include_context 'extractor setup'

  let(:unit) do
    create_file('lib/first/contributor_owner.rb', "module ContributorOwner\n  def first; 'é'; end\nend\n")
    create_file('lib/second/contributor_owner.rb', "module ContributorOwner\n\n  def second; :two; end\nend\n")
    Woods::Extractors::LibExtractor.new.extract_all.fetch(0)
  end

  it 'maps original Unicode bytes to the secondary physical file and excludes generated text' do
    record = described_class.records(unit).last
    result = described_class.physical_span(unit, start_byte: record['published_start_byte'],
                                                 end_byte: record['published_end_byte'])
    expect(result).to include(file_path: record['file_path'], start_line: 1, end_line: 4,
                              source_sha256: record['source_sha256'])
    expect(described_class.physical_span(unit, start_byte: 0, end_byte: unit.source_code.bytesize)).to be_nil
  end

  it 'rejects forged versions, paths, overlapping/out-of-bounds ranges and mismatched original hashes' do
    [->(data) { data['metadata']['source_contributors_version'] = 0 },
     ->(data) { data['metadata']['source_contributors'][0]['file_path'] = 'lib/../../outside.rb' },
     ->(data) { data['metadata']['source_contributors'][1]['published_start_byte'] = 0 },
     ->(data) { data['metadata']['source_contributors'][1]['published_end_byte'] = 100_000 },
     ->(data) { data['metadata']['source_contributors'][0]['source_sha256'] = '0' * 64 }].each do |corrupt|
      data = JSON.parse(JSON.generate(unit.to_h))
      corrupt.call(data)
      expect { described_class.records(data) }.to raise_error(described_class::Invalid)
    end
  end

  it 'labels composite evidence and cites selected methods using physical contributor coordinates' do
    result = Woods::Retrieval::SourceEvidence.new(unit: unit.to_h, query: 'second')
                                             .render(mode: 'compact', budget: 2000, counter: ->(text) { text.size / 4 })
    expect(result.text).to include('Primary file:', 'Contributing files:')
    span = result.provenance[:spans].find { |entry| entry[:name] == 'second' }
    expect(span[:physical_location]).to include(file_path: 'lib/second/contributor_owner.rb', start_line: 3,
                                                end_line: 3)
    expect(result.provenance[:physical_location]).to be_nil
  end

  it 'accepts a scoped aggregate only when every contributor matches all requested dimensions' do
    resolver = double(package_for: nil)
    allow(resolver).to receive(:package_for).with('lib/first/contributor_owner.rb').and_return('one')
    allow(resolver).to receive(:package_for).with('lib/second/contributor_owner.rb').and_return('two')
    expect(described_class.annotate_package(unit, resolver)).to be_nil
    store = Woods::Storage::MetadataStore::InMemory.new
    store.store(unit.identifier, JSON.parse(JSON.generate(unit.to_h)))
    scope = ->(**options) { Woods::Retrieval::Scope.new(metadata_store: store, **options).keys }
    expect(scope.call(packages: ['one'])).to be_empty
    expect(scope.call(source_paths: ['lib/first'])).to be_empty
    expect(scope.call(packages: %w[one two], source_paths: %w[lib/first lib/second])).to eq([unit.identifier])
  end

  it 'keeps per-file Git facts and clears an arbitrary primary-file aggregate history' do
    unit.metadata[:git] = { commit_count: 100 }
    paths = described_class.paths(unit)
    described_class.annotate_git(unit, paths.first => { commit_count: 1 }, paths.last => { commit_count: 2 })
    expect(unit.metadata).not_to have_key(:git)
    expect(described_class.records(unit).map { |record| record['git'][:commit_count] }).to eq([1, 2])
  end
end
