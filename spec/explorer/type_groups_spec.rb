# frozen_string_literal: true

require 'spec_helper'
require 'woods/explorer/type_groups'

RSpec.describe Woods::Explorer::TypeGroups do
  describe '.group_for' do
    {
      'model' => 'data',
      'controller' => 'http',
      'view_template' => 'view',
      'service' => 'domain',
      'job' => 'async',
      'policy' => 'policy',
      'factory' => 'test',
      'concern' => 'support',
      'rails_source' => 'other'
    }.each do |type, family|
      it "maps #{type} to the #{family} family" do
        expect(described_class.group_for(type)).to eq(family)
      end
    end

    it 'buckets an unknown type into other' do
      expect(described_class.group_for('quantum_flux')).to eq('other')
    end

    it 'accepts symbol input via to_s' do
      expect(described_class.group_for(:model)).to eq('data')
    end
  end

  describe '.all' do
    it 'returns the families in slot order, ending with the other bucket' do
      keys = described_class.all.map { |family| family[:key] }
      expect(keys).to eq(%w[data http view domain async policy test support other])
    end

    it 'gives every family a unique key' do
      keys = described_class.all.map { |family| family[:key] }
      expect(keys.uniq).to eq(keys)
    end

    it 'gives every family a label and a glyph' do
      described_class.all.each do |family|
        expect(family[:label]).to be_a(String).and(satisfy { |l| !l.empty? })
        expect(family[:glyph]).to be_a(String).and(satisfy { |g| !g.empty? })
      end
    end
  end

  describe 'type assignments' do
    it 'maps every type to at most one family' do
      all_types = described_class.all.flat_map { |family| family[:types] }
      expect(all_types.uniq).to eq(all_types)
    end

    it 'covers every unit type IndexReader can serve (new extractors must pick a family)' do
      require 'woods/mcp/index_reader'
      # 'graphql' is a directory-level pseudo-type (the real unit types are
      # graphql_type/graphql_mutation/graphql_resolver/graphql_query, all
      # mapped); rails_source deliberately renders in the muted other bucket.
      deliberately_unmapped = %w[graphql rails_source]
      expected = Woods::MCP::IndexReader::DIR_TO_TYPE.values - deliberately_unmapped

      unplaced = expected - described_class::TYPE_TO_GROUP.keys
      expect(unplaced).to be_empty,
                          "unit types without a family (they'd silently render as 'other'): #{unplaced.inspect}"
    end
  end
end
