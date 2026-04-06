# frozen_string_literal: true

require 'spec_helper'
require 'woods/svelte_flow/association_edge_builder'

RSpec.describe Woods::SvelteFlow::AssociationEdgeBuilder do
  describe '#build' do
    it 'produces a belongs_to edge with FK→PK direction' do
      unit_metadata = {
        'Order' => {
          'type' => 'model',
          'metadata' => {
            'primary_key' => 'id',
            'columns' => [
              { 'name' => 'id', 'type' => 'bigint' },
              { 'name' => 'account_id', 'type' => 'bigint' }
            ],
            'associations' => [
              { 'type' => 'belongs_to', 'target' => 'Account', 'foreign_key' => 'account_id' }
            ]
          }
        },
        'Account' => {
          'type' => 'model',
          'metadata' => {
            'primary_key' => 'id',
            'columns' => [
              { 'name' => 'id', 'type' => 'bigint' }
            ],
            'associations' => []
          }
        }
      }

      builder = described_class.new(unit_metadata: unit_metadata, cycle_edges: Set.new)
      edges = builder.build

      expect(edges.size).to eq(1)
      edge = edges.first
      expect(edge['source']).to eq('Order')
      expect(edge['target']).to eq('Account')
      expect(edge['type']).to eq('association')
      expect(edge['data']['via']).to eq('belongs_to')
      expect(edge['data']['foreignKey']).to eq('account_id')
      expect(edge['data']['sourceHandle']).to eq('Order-account_id')
      expect(edge['data']['targetHandle']).to eq('Account-id')
      expect(edge['data']['through']).to be_nil
      expect(edge['data']['polymorphic']).to eq(false)
    end

    it 'flips has_many edges so FK holder is source' do
      unit_metadata = {
        'Account' => {
          'type' => 'model',
          'metadata' => {
            'primary_key' => 'id',
            'columns' => [{ 'name' => 'id', 'type' => 'bigint' }],
            'associations' => [
              { 'type' => 'has_many', 'target' => 'Order', 'foreign_key' => 'account_id' }
            ]
          }
        },
        'Order' => {
          'type' => 'model',
          'metadata' => {
            'primary_key' => 'id',
            'columns' => [
              { 'name' => 'id', 'type' => 'bigint' },
              { 'name' => 'account_id', 'type' => 'bigint' }
            ],
            'associations' => []
          }
        }
      }

      builder = described_class.new(unit_metadata: unit_metadata, cycle_edges: Set.new)
      edges = builder.build

      expect(edges.size).to eq(1)
      edge = edges.first
      expect(edge['source']).to eq('Order')
      expect(edge['target']).to eq('Account')
      expect(edge['data']['via']).to eq('has_many')
      expect(edge['data']['sourceHandle']).to eq('Order-account_id')
      expect(edge['data']['targetHandle']).to eq('Account-id')
    end

    it 'deduplicates bidirectional associations' do
      unit_metadata = {
        'Account' => {
          'type' => 'model',
          'metadata' => {
            'primary_key' => 'id',
            'columns' => [{ 'name' => 'id', 'type' => 'bigint' }],
            'associations' => [
              { 'type' => 'has_many', 'target' => 'Order', 'foreign_key' => 'account_id' }
            ]
          }
        },
        'Order' => {
          'type' => 'model',
          'metadata' => {
            'primary_key' => 'id',
            'columns' => [
              { 'name' => 'id', 'type' => 'bigint' },
              { 'name' => 'account_id', 'type' => 'bigint' }
            ],
            'associations' => [
              { 'type' => 'belongs_to', 'target' => 'Account', 'foreign_key' => 'account_id' }
            ]
          }
        }
      }

      builder = described_class.new(unit_metadata: unit_metadata, cycle_edges: Set.new)
      edges = builder.build
      expect(edges.size).to eq(1)
    end

    it 'includes through field for has_many :through' do
      unit_metadata = {
        'Doctor' => {
          'type' => 'model',
          'metadata' => {
            'primary_key' => 'id',
            'columns' => [{ 'name' => 'id', 'type' => 'bigint' }],
            'associations' => [
              { 'type' => 'has_many', 'target' => 'Patient', 'foreign_key' => 'doctor_id',
                'through' => 'Appointment' }
            ]
          }
        },
        'Patient' => {
          'type' => 'model',
          'metadata' => {
            'primary_key' => 'id',
            'columns' => [{ 'name' => 'id', 'type' => 'bigint' }],
            'associations' => []
          }
        }
      }

      builder = described_class.new(unit_metadata: unit_metadata, cycle_edges: Set.new)
      edges = builder.build
      expect(edges.size).to eq(1)
      expect(edges.first['data']['through']).to eq('Appointment')
    end

    it 'flags polymorphic associations' do
      unit_metadata = {
        'Comment' => {
          'type' => 'model',
          'metadata' => {
            'primary_key' => 'id',
            'columns' => [
              { 'name' => 'id', 'type' => 'bigint' },
              { 'name' => 'commentable_id', 'type' => 'bigint' }
            ],
            'associations' => [
              { 'type' => 'belongs_to', 'target' => 'Post', 'foreign_key' => 'commentable_id',
                'polymorphic' => true }
            ]
          }
        },
        'Post' => {
          'type' => 'model',
          'metadata' => {
            'primary_key' => 'id',
            'columns' => [{ 'name' => 'id', 'type' => 'bigint' }],
            'associations' => []
          }
        }
      }

      builder = described_class.new(unit_metadata: unit_metadata, cycle_edges: Set.new)
      edges = builder.build
      expect(edges.first['data']['polymorphic']).to eq(true)
    end

    it 'marks cycle edges' do
      unit_metadata = {
        'A' => {
          'type' => 'model',
          'metadata' => {
            'primary_key' => 'id',
            'columns' => [
              { 'name' => 'id', 'type' => 'bigint' },
              { 'name' => 'b_id', 'type' => 'bigint' }
            ],
            'associations' => [
              { 'type' => 'belongs_to', 'target' => 'B', 'foreign_key' => 'b_id' }
            ]
          }
        },
        'B' => {
          'type' => 'model',
          'metadata' => {
            'primary_key' => 'id',
            'columns' => [{ 'name' => 'id', 'type' => 'bigint' }],
            'associations' => []
          }
        }
      }

      cycle_edges = Set.new([%w[A B]])
      builder = described_class.new(unit_metadata: unit_metadata, cycle_edges: cycle_edges)
      edges = builder.build
      expect(edges.first['data']['isCycle']).to eq(true)
    end

    it 'skips non-model units' do
      unit_metadata = {
        'UsersController' => {
          'type' => 'controller',
          'metadata' => {
            'associations' => []
          }
        }
      }

      builder = described_class.new(unit_metadata: unit_metadata, cycle_edges: Set.new)
      expect(builder.build).to eq([])
    end

    it 'skips associations whose target is not in unit_metadata' do
      unit_metadata = {
        'Order' => {
          'type' => 'model',
          'metadata' => {
            'primary_key' => 'id',
            'columns' => [{ 'name' => 'id', 'type' => 'bigint' }],
            'associations' => [
              { 'type' => 'belongs_to', 'target' => 'MissingModel', 'foreign_key' => 'missing_model_id' }
            ]
          }
        }
      }

      builder = described_class.new(unit_metadata: unit_metadata, cycle_edges: Set.new)
      expect(builder.build).to eq([])
    end
  end
end
