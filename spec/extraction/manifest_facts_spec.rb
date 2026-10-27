# frozen_string_literal: true

# This contract can run with --options /dev/null and only RSpec plus JSON.
# The normal repository suite still applies its standard spec_helper hooks.
require 'rspec'
require 'json'
require_relative '../../lib/woods/extraction/manifest_facts'

RSpec.describe Woods::Extraction::ManifestFacts do
  let(:counts) { { controllers: 0, models: 2 } }
  let(:provenance) { { git_sha: 'captured-commit', git_branch: 'main' } }
  let(:configuration) { { 'include_framework_sources' => 'digest' } }
  let(:git_enrichment) do
    { 'state' => 'available', 'head_sha' => 'captured-commit',
      'capture' => { 'refreshed' => 1, 'retained' => 1 } }
  end
  let(:facts) do
    {
      extracted_at: '2026-10-27T12:00:00Z', woods_version: '2.1.1.alpha',
      rails_version: '8.1.0', ruby_version: '4.0.7', counts: counts,
      total_chunks: 0, provenance: provenance, gemfile_lock_sha: nil, schema_sha: 'schema-digest',
      extraction_config: configuration, git_enrichment: git_enrichment, git_filter_available: true
    }
  end
  let(:expected) do
    {
      extracted_at: '2026-10-27T12:00:00Z', woods_version: '2.1.1.alpha',
      rails_version: '8.1.0', ruby_version: '4.0.7', counts: { controllers: 0, models: 2 },
      total_units: 2, total_chunks: 0, git_sha: 'captured-commit', git_branch: 'main',
      gemfile_lock_sha: nil, schema_sha: 'schema-digest',
      extraction_config: { 'include_framework_sources' => 'digest' },
      git_enrichment: { 'state' => 'available', 'head_sha' => 'captured-commit',
                        'capture' => { 'refreshed' => 1, 'retained' => 1 } }
    }
  end

  def build(**overrides)
    described_class.build(**facts, **overrides)
  end

  it 'owns the complete field shape and preserves insertion order including zero-count categories' do
    result = build

    expect(result).to eq(expected)
    expect(result.keys).to eq(%i[extracted_at woods_version rails_version ruby_version counts total_units total_chunks
                                 git_sha git_branch gemfile_lock_sha schema_sha extraction_config git_enrichment])
    expect(result.fetch(:counts).keys).to eq(%i[controllers models])
  end

  it 'preserves complete compact bytes including null and nested field order' do
    expected_bytes = '{"extracted_at":"2026-10-27T12:00:00Z","woods_version":"2.1.1.alpha",' \
                     '"rails_version":"8.1.0","ruby_version":"4.0.7","counts":{"controllers":0,"models":2},' \
                     '"total_units":2,"total_chunks":0,"git_sha":"captured-commit","git_branch":"main",' \
                     '"gemfile_lock_sha":null,"schema_sha":"schema-digest",' \
                     '"extraction_config":{"include_framework_sources":"digest"},' \
                     '"git_enrichment":{"state":"available","head_sha":"captured-commit",' \
                     '"capture":{"refreshed":1,"retained":1}}}'

    expect(JSON.generate(build)).to eq(expected_bytes)
  end

  it 'preserves complete pretty bytes without taking ownership of serialization' do
    expected_bytes = <<~JSON.chomp
      {
        "extracted_at": "2026-10-27T12:00:00Z",
        "woods_version": "2.1.1.alpha",
        "rails_version": "8.1.0",
        "ruby_version": "4.0.7",
        "counts": {
          "controllers": 0,
          "models": 2
        },
        "total_units": 2,
        "total_chunks": 0,
        "git_sha": "captured-commit",
        "git_branch": "main",
        "gemfile_lock_sha": null,
        "schema_sha": "schema-digest",
        "extraction_config": {
          "include_framework_sources": "digest"
        },
        "git_enrichment": {
          "state": "available",
          "head_sha": "captured-commit",
          "capture": {
            "refreshed": 1,
            "retained": 1
          }
        }
      }
    JSON

    expect(JSON.pretty_generate(build)).to eq(expected_bytes)
  end

  it 'sums empty and zero Integer counts without inventing units or a minimum chunk count' do
    expect(build(counts: {})).to include(counts: {}, total_units: 0, total_chunks: 0)
    expect(build(counts: { models: 0, controllers: 0 })).to include(total_units: 0, total_chunks: 0)
  end

  it 'omits absent configuration but preserves an explicitly present empty fingerprint' do
    result = build(extraction_config: nil)
    expect(result).not_to have_key(:extraction_config)
    expect(result.keys.last).to eq(:git_enrichment)
    expect(build(extraction_config: {})).to have_key(:extraction_config)
    expect(build(extraction_config: {}).fetch(:extraction_config)).to eq({})
  end

  it 'adds only the existing unavailable-filter metadata after Git enrichment' do
    result = build(git_filter_available: false, extraction_config: nil)

    expect(result.fetch(:metadata)).to eq(git_filter: 'unavailable')
    expect(result.keys.last(2)).to eq(%i[git_enrichment metadata])
    expect(build).not_to have_key(:metadata)
  end

  it 'preserves unknown and missing provenance without discovering another revision' do
    expect(build(provenance: { git_sha: 'unknown', git_branch: 'unknown' }))
      .to include(git_sha: 'unknown', git_branch: 'unknown')
    expect(build(provenance: {})).to include(git_sha: nil, git_branch: nil)
    expect(build(provenance: { git_sha: nil, git_branch: nil }))
      .to include(git_sha: nil, git_branch: nil)
  end

  it 'preserves unavailable history and retained coverage exactly as computed by the caller' do
    unavailable = { 'state' => 'unavailable', 'reason' => 'history_read_failed', 'head_sha' => nil,
                    'coverage' => { 'with_facts' => 0 }, 'capture' => { 'refreshed' => 0, 'retained' => 2 } }

    expect(build(git_enrichment: unavailable).fetch(:git_enrichment)).to equal(unavailable)
    expect(build.fetch(:git_enrichment)).to equal(git_enrichment)
  end

  it 'composes fresh output containers without mutating or freezing supplied facts' do
    before = Marshal.dump(facts)
    first = build(git_filter_available: false)
    second = build(git_filter_available: false)

    expect(Marshal.dump(facts)).to eq(before)
    expect(first).not_to equal(second)
    expect(first.fetch(:metadata)).not_to equal(second.fetch(:metadata))
    expect(first.fetch(:counts)).to equal(counts)
    expect(first.fetch(:extraction_config)).to equal(configuration)
    expect(first).not_to be_frozen
    expect(counts).not_to be_frozen
  end

  it 'preserves nested values for the existing serializer rather than canonicalizing them' do
    ordered = { 'z' => '<tag>', :a => { 'nested' => [nil, 2, 'é'] } }
    result = build(extraction_config: ordered)

    expect(result.fetch(:extraction_config)).to equal(ordered)
    expect(result.fetch(:extraction_config).keys).to eq(['z', :a])
    expect(JSON.generate(result)).to include('"extraction_config":{"z":"<tag>","a":{"nested":[null,2,"é"]}}')
  end
end
