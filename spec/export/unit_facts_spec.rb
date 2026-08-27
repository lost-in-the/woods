# frozen_string_literal: true

require 'spec_helper'
require 'woods/export/unit_facts'

RSpec.describe Woods::Export::UnitFacts do
  let(:unit) do
    {
      'type' => 'model', 'identifier' => 'Order',
      'metadata' => {
        'associations' => [
          { 'type' => 'belongs_to', 'target' => 'User' },
          { 'type' => 'has_many', 'target' => 'LineItem', 'options' => { 'dependent' => 'destroy' } },
          { 'type' => 'has_many', 'target' => 'Payment' }
        ],
        'enums' => { 'status' => %w[pending paid] },
        'scopes' => [{ 'name' => 'recent' }, { 'name' => 'paid' }],
        'inlined_concerns' => %w[Auditable],
        'callbacks' => [{ 'type' => 'before_save', 'filter' => 'normalize' }]
      }
    }
  end

  subject(:facts) { described_class.new(unit) }

  describe '#associations_by_type' do
    it 'groups associations by macro into structured {target, dependent} entries' do
      expect(facts.associations_by_type).to eq(
        'belongs_to' => [{ target: 'User', dependent: nil }],
        'has_many' => [
          { target: 'LineItem', dependent: 'destroy' },
          { target: 'Payment', dependent: nil }
        ]
      )
    end

    it 'falls back to the association name when target is absent' do
      u = { 'metadata' => { 'associations' => [{ 'type' => 'has_one', 'name' => 'Profile' }] } }
      expect(described_class.new(u).associations_by_type['has_one']).to eq([{ target: 'Profile', dependent: nil }])
    end

    it 'returns an empty hash when there are no associations' do
      expect(described_class.new({ 'metadata' => {} }).associations_by_type).to eq({})
    end
  end

  describe '#association_count' do
    it 'counts all associations regardless of macro' do
      expect(facts.association_count).to eq(3)
    end
  end

  describe '#schema_highlights' do
    it 'extracts structured enums, scopes, concerns, and callbacks' do
      expect(facts.schema_highlights).to eq(
        enums: { 'status' => %w[pending paid] },
        scopes: %w[recent paid],
        concerns: %w[Auditable],
        callbacks: [{ type: 'before_save', filter: 'normalize' }]
      )
    end

    it 'returns empty collections when metadata is missing the sections' do
      expect(described_class.new({}).schema_highlights).to eq(
        enums: {}, scopes: [], concerns: [], callbacks: []
      )
    end
  end
end
