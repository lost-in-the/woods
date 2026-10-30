# frozen_string_literal: true

require 'spec_helper'
require 'woods/extractor'
require 'woods/temporal/snapshot_store'

RSpec.describe Woods::Extractor, 'snapshot fact projection' do
  include_context 'isolated Woods runtime'

  let(:store) { instance_double(Woods::Temporal::SnapshotStore, capture: nil) }
  let(:logger) { double('Logger').as_null_object }
  let(:extractor) { described_class.new(output_dir: @output_dir) }
  let(:manifest) { { 'git_sha' => 'abc123', 'extracted_at' => '2026-01-01T00:00:00Z' } }
  let(:unit) do
    Woods::ExtractedUnit.new(type: :graphql_query, identifier: 'Shared', file_path: nil).tap do |value|
      value.source_code = "café\n"
      value.metadata = { 'z' => [1, nil], 'a' => { 'value' => true } }
      value.dependencies = [{ target: 'Shared', via: :code_reference }, { target: 'Other', via: :service }]
    end
  end

  around do |example|
    Dir.mktmpdir('woods_snapshot_facts') do |directory|
      @output_dir = directory
      example.run
    end
  end

  before do
    stub_const('Rails', double('Rails', logger: logger))
    Woods.configuration.enable_snapshots = true
    File.write(File.join(@output_dir, 'manifest.json'), JSON.generate(manifest))
    allow(extractor).to receive(:build_snapshot_store).and_return(store)
    extractor.instance_variable_set(:@results, graphql: [unit])
  end

  it 'captures exact fingerprints in group order using actual unit types and preserving shared identifiers' do
    other = Woods::ExtractedUnit.new(type: :gem_source, identifier: 'Shared', file_path: nil)
    extractor.instance_variable_set(:@results, graphql: [unit], empty: [], rails_source: [other])

    expected = [
      { 'identifier' => 'Shared', 'type' => 'graphql_query',
        'source_hash' => '7b49b9e063bd91a4f9252b413261f5557b9c570aa61516989499f64a62dbcdd6',
        'metadata_hash' => 'ebcffeb133e3d68b6ea3a1bbe257a74d64866787e2dd86b023950f2ffbbf7b01',
        'dependencies_hash' => 'd5d82a1bf1a4757cd3e5f63c02adb1b66d36bf71cf970f0ea15c2ae025b4d4ce' },
      { 'identifier' => 'Shared', 'type' => 'gem_source',
        'source_hash' => 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
        'metadata_hash' => '44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a',
        'dependencies_hash' => '4f53cda18c2baa0c0354bb5f9a3ecbe5ed12ab4d8e11ba873c2f11161202b945' }
    ]
    expect(store).to receive(:capture).with(manifest, expected)

    extractor.send(:capture_snapshot)
  end

  it 'logs a projection failure without capturing a partial snapshot or raising' do
    allow(unit.metadata).to receive(:to_json).and_raise(StandardError, 'projection failed')
    expect(store).not_to receive(:capture)
    expect(logger).to receive(:error).with('[Woods] Snapshot capture failed (StandardError): projection failed')

    expect { extractor.send(:capture_snapshot) }.not_to raise_error
  end

  %i[disabled missing_manifest nil_sha unknown_sha unavailable_store].each do |condition|
    it "does not read unit source when snapshot capture is #{condition}" do
      case condition
      when :disabled then Woods.configuration.enable_snapshots = false
      when :missing_manifest then FileUtils.rm_f(File.join(@output_dir, 'manifest.json'))
      when :nil_sha, :unknown_sha
        sha = condition == :nil_sha ? nil : Woods::GitProvenance::UNKNOWN
        File.write(File.join(@output_dir, 'manifest.json'), JSON.generate(manifest.merge('git_sha' => sha)))
      when :unavailable_store then allow(extractor).to receive(:build_snapshot_store).and_return(nil)
      end
      expect(unit).not_to receive(:source_code)
      expect(store).not_to receive(:capture)

      extractor.send(:capture_snapshot)
    end
  end
end
