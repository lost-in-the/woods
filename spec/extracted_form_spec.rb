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

    it 'ignores pass-derived reference metadata when deciding whether fresh extraction is retainable' do
      published = unit('metadata' => { 'queue' => 'default', 'references' => [{ 'target' => 'Ledger' }] })
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

  describe '.before_tables' do
    let(:callbacks) { [{ 'type' => 'before_save', 'filter' => 'ship', 'declaration' => { 'line' => 2 } }] }
    let(:tables) do
      { 'queue' => 'default', 'methods' => [{ 'name' => 'ship' }], 'examples' => [], 'callbacks' => callbacks,
        'filters' => [{ 'kind' => 'before', 'filter' => 'auth', 'declaration' => { 'line' => 3 } }] }
    end
    let(:bare) do
      { 'queue' => 'default', 'callbacks' => [{ 'type' => 'before_save', 'filter' => 'ship' }],
        'filters' => [{ 'kind' => 'before', 'filter' => 'auth' }] }
    end

    it 'ignores the method and example tables and declaration sites, and everything .of ignores' do
      published = unit('metadata' => tables.merge('git' => { 'commit_count' => 1 }),
                       'dependencies' => [edge, reference_edge], 'extracted_at' => 'later')

      expect(described_class.before_tables(published, reference_edges: [reference_edge]))
        .to eq(described_class.before_tables(unit('metadata' => bare)))
    end

    it 'still differs on source, other metadata, and the callback list itself' do
      baseline = described_class.before_tables(unit('metadata' => bare))

      expect(described_class.before_tables(unit('source_code' => "class ShipmentJob; end\n", 'metadata' => bare)))
        .not_to eq(baseline)
      expect(described_class.before_tables(unit('metadata' => bare.merge('queue' => 'low')))).not_to eq(baseline)
      expect(described_class.before_tables(unit('metadata' => bare.merge('callbacks' => [])))).not_to eq(baseline)
    end

    it 'is nil when a recorded reference edge is missing, and does not mutate its argument' do
      published = unit('metadata' => tables)
      copy = Marshal.load(Marshal.dump(published))

      expect(described_class.before_tables(published, reference_edges: [reference_edge])).to be_nil
      expect(described_class.before_tables(published)).to eq(described_class.of(unit('metadata' => bare)))
      expect(published).to eq(copy)
    end
  end

  # #994: a caller whose flow refresh reconciles the annotation compares
  # without it. Everything else about the unit still counts.
  describe '.without_flow_annotation' do
    let(:annotated) do
      unit('metadata' => { 'queue' => 'default', 'flow_paths' => { 'show' => 'flows/ShipmentJob_show.json' } })
    end

    it 'makes an annotated unit compare equal to the same unit without the annotation' do
      expect(described_class.before_tables(described_class.without_flow_annotation(annotated)))
        .to eq(described_class.before_tables(unit))
    end

    it 'keeps every other difference, including a nested key of the same name' do
      changed = described_class.without_flow_annotation(
        unit('metadata' => { 'queue' => 'low', 'flow_paths' => { 'show' => 'f' } })
      )
      nested = unit('metadata' => { 'queue' => 'default', 'options' => { 'flow_paths' => 'kept' } })

      expect(described_class.of(changed)).not_to eq(described_class.of(unit))
      expect(described_class.without_flow_annotation(nested)).to eq(nested)
    end

    it 'returns a unit without the annotation, or without metadata, as it is, and does not mutate its argument' do
      copy = Marshal.load(Marshal.dump(annotated))
      plain = unit
      bare = unit.except('metadata')

      described_class.without_flow_annotation(annotated)

      expect(annotated).to eq(copy)
      expect(described_class.without_flow_annotation(plain)).to equal(plain)
      expect(described_class.without_flow_annotation(bare)).to equal(bare)
    end
  end

  describe '.own_dependencies' do
    it 'returns the published edges without the recorded additions' do
      expect(described_class.own_dependencies([edge, reference_edge], [reference_edge])).to eq([edge])
    end
  end
end
