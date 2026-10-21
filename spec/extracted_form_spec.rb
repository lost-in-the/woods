# frozen_string_literal: true

require 'spec_helper'
require 'woods/extracted_form'

RSpec.describe Woods::ExtractedForm do
  let(:edge) { { 'type' => 'model', 'target' => 'Widget', 'via' => 'code_reference' } }
  let(:reference_edge) { { 'type' => 'service', 'target' => 'Ledger', 'via' => 'constant_reference' } }

  def unit(overrides = {})
    {
      'type' => 'job', 'identifier' => 'ShipmentJob', 'file_path' => 'app/jobs/shipment_job.rb',
      'source_code' => "class ShipmentJob\nend\n", 'metadata' => { 'queue' => 'default' },
      'dependencies' => [edge], 'dependents' => [], 'chunks' => [],
      'extracted_at' => '2026-01-01T00:00:00Z', 'source_hash' => 'a' * 64
    }.merge(overrides)
  end

  describe '.of' do
    it 'ignores dependents, the extraction stamp, and git metadata' do
      published = unit(
        'dependents' => [{ 'type' => 'scheduled_job', 'identifier' => 'scheduled:shipments' }],
        'extracted_at' => '2026-02-02T00:00:00Z',
        'metadata' => { 'queue' => 'default', 'git' => { 'commit_count' => 3 } }
      )

      expect(described_class.of(published)).to eq(described_class.of(unit))
    end

    it 'ignores git facts on source contributor records' do
      contributors = [{ 'file_path' => 'app/jobs/shipment_job.rb', 'git' => { 'commit_count' => 3 } }]
      bare = [{ 'file_path' => 'app/jobs/shipment_job.rb' }]

      expect(described_class.of(unit('metadata' => { 'source_contributors' => contributors })))
        .to eq(described_class.of(unit('metadata' => { 'source_contributors' => bare })))
    end

    it 'removes the edges the source-reference pass added, once each' do
      published = unit('dependencies' => [edge, reference_edge])

      expect(described_class.of(published, reference_edges: [reference_edge])).to eq(described_class.of(unit))
    end

    it 'is nil when a recorded reference edge is missing from the published unit' do
      expect(described_class.of(unit, reference_edges: [reference_edge])).to be_nil
    end

    it 'differs when source, metadata, edges, or key order differ' do
      baseline = described_class.of(unit)

      expect(described_class.of(unit('source_code' => "class ShipmentJob; end\n"))).not_to eq(baseline)
      expect(described_class.of(unit('metadata' => { 'queue' => 'low' }))).not_to eq(baseline)
      expect(described_class.of(unit('dependencies' => []))).not_to eq(baseline)
      expect(described_class.of(unit.to_a.reverse.to_h)).not_to eq(baseline)
    end

    it 'keeps a nested metadata field named extracted_at and flow annotations' do
      baseline = described_class.of(unit)

      expect(described_class.of(unit('metadata' => { 'queue' => 'default', 'extracted_at' => 'x' })))
        .not_to eq(baseline)
      expect(described_class.of(unit('metadata' => { 'queue' => 'default', 'flow_paths' => { 'show' => 'f' } })))
        .not_to eq(baseline)
    end

    it 'does not mutate its argument' do
      published = unit('metadata' => { 'git' => { 'commit_count' => 1 } }, 'dependencies' => [edge, reference_edge])
      copy = Marshal.load(Marshal.dump(published))

      described_class.of(published, reference_edges: [reference_edge])

      expect(published).to eq(copy)
    end
  end

  describe '.own_dependencies' do
    it 'returns the published edges without the recorded additions' do
      expect(described_class.own_dependencies([edge, reference_edge], [reference_edge])).to eq([edge])
    end
  end
end
