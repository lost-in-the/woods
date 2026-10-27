# frozen_string_literal: true

require 'spec_helper'
require 'open3'
require 'rbconfig'
require 'woods/temporal/snapshot_unit_facts'

RSpec.describe Woods::Temporal::SnapshotUnitFacts do
  let(:unit_class) { Struct.new(:identifier, :type, :source_code, :metadata, :dependencies) }
  let(:unit) { unit_class.new('Shared', :graphql_query, nil, {}, []) }

  it 'returns an empty record list for empty groups' do
    expect(described_class.build(unit_groups: [])).to eq([])
    expect(described_class.build(unit_groups: [[], []])).to eq([])
  end

  it 'preserves group and unit order, actual types and shared identifiers' do
    other = unit_class.new('Shared', :gem_source, nil, {}, [])
    records = described_class.build(unit_groups: [[unit], [], [other, unit]])

    expect(records.map { |record| record.values_at('identifier', 'type') })
      .to eq([%w[Shared graphql_query], %w[Shared gem_source], %w[Shared graphql_query]])
    expect(records.first.keys).to eq(%w[identifier type source_hash metadata_hash dependencies_hash])
    expect(records.first.fetch('identifier')).to equal(unit.identifier)
  end

  it 'hashes nil source as empty text and preserves empty JSON fingerprint bytes' do
    expect(described_class.build(unit_groups: [[unit]]).first).to include(
      'source_hash' => 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
      'metadata_hash' => '44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a',
      'dependencies_hash' => '4f53cda18c2baa0c0354bb5f9a3ecbe5ed12ab4d8e11ba873c2f11161202b945'
    )
  end

  it 'preserves custom to_json dispatch instead of canonicalizing values' do
    unit.metadata = Class.new(Hash) do
      def to_json(*)
        '{"kept":true}'
      end
    end.new
    unit.dependencies = Class.new(Array) do
      def to_json(*)
        '["kept"]'
      end
    end.new

    expect(described_class.build(unit_groups: [[unit]]).first).to include(
      'metadata_hash' => '3abf51432c3f669f8dbbc0037824e18b6e263fa34b8b05153cc0a137159c39e4',
      'dependencies_hash' => '9a96c1d7282fefd3a14dc0edccbc1b41aa94e3f3a64ec355b2470c4ca31a2714'
    )
  end

  it 'returns fresh record containers without modifying frozen input values' do
    unit.identifier.freeze
    unit.metadata.freeze
    unit.dependencies.freeze
    groups = [[unit].freeze].freeze
    first = described_class.build(unit_groups: groups)
    first.first['type'] = 'changed'
    second = described_class.build(unit_groups: groups)

    expect(second.first.fetch('type')).to eq('graphql_query')
    expect(second).not_to equal(first)
    expect(second.first).not_to equal(first.first)
    expect(unit.type).to eq(:graphql_query)
    expect(unit.metadata).to eq({})
    expect(unit.dependencies).to eq([])
  end

  { source_code: 'source_hash', metadata: 'metadata_hash',
    dependencies: 'dependencies_hash' }.each do |attribute, fingerprint|
    it "changes only #{fingerprint} when #{attribute} changes between calls" do
      before = described_class.build(unit_groups: [[unit]]).first
      replacement = { source_code: 'changed', metadata: { 'changed' => true }, dependencies: [{ target: 'Other' }] }
      unit.public_send("#{attribute}=", replacement.fetch(attribute))
      after = described_class.build(unit_groups: [[unit]]).first

      expect(after.fetch(fingerprint)).not_to eq(before.fetch(fingerprint))
      expect(after.except(fingerprint)).to eq(before.except(fingerprint))
    end
  end

  it 'lets serialization errors reach the snapshot capture error boundary' do
    allow(unit.metadata).to receive(:to_json).and_raise(StandardError, 'cannot serialize')

    expect { described_class.build(unit_groups: [[unit]]) }.to raise_error(StandardError, 'cannot serialize')
  end

  it 'loads independently of Extractor, Rails, configuration and snapshot backends' do
    lib = File.expand_path('../../lib', __dir__)
    probe = <<~RUBY
      puts JSON.generate([defined?(Woods::Extractor), defined?(Rails), defined?(SQLite3),
                          Woods.respond_to?(:configuration)])
    RUBY
    output, error, status = Open3.capture3(RbConfig.ruby, '-I', lib, '-rwoods/temporal/snapshot_unit_facts', '-e',
                                           probe)

    expect(status.success?).to be(true), error
    expect(JSON.parse(output)).to eq([nil, nil, nil, false])
  end
end
