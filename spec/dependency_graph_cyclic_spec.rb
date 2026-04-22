# frozen_string_literal: true

require 'spec_helper'
require 'json'

RSpec.describe Woods::DependencyGraph, 'cyclic graph behavior' do
  let(:graph) { described_class.new }

  def make_unit(type:, identifier:, file_path: nil, dependencies: [])
    unit = Woods::ExtractedUnit.new(
      type: type,
      identifier: identifier,
      file_path: file_path || "/app/#{identifier.downcase}.rb"
    )
    unit.dependencies = dependencies
    unit
  end

  # Helper: build the A → B → A cycle
  def register_ab_cycle
    graph.register(make_unit(
                     type: :model, identifier: 'A',
                     dependencies: [{ type: :model, target: 'B', via: :belongs_to }]
                   ))
    graph.register(make_unit(
                     type: :model, identifier: 'B',
                     dependencies: [{ type: :model, target: 'A', via: :belongs_to }]
                   ))
  end

  describe '#dependencies_of on a cyclic graph' do
    before { register_ab_cycle }

    it 'returns direct dependencies for a node involved in a cycle' do
      expect(graph.dependencies_of('A')).to contain_exactly('B')
      expect(graph.dependencies_of('B')).to contain_exactly('A')
    end

    it 'filters by via label within a cycle' do
      expect(graph.dependencies_of('A', via: :belongs_to)).to eq(['B'])
      expect(graph.dependencies_of('A', via: :code_reference)).to be_empty
    end
  end

  describe '#dependents_of on a cyclic graph' do
    before { register_ab_cycle }

    it 'returns correct direct dependents in a mutual dependency' do
      expect(graph.dependents_of('A')).to contain_exactly('B')
      expect(graph.dependents_of('B')).to contain_exactly('A')
    end

    it 'filters dependents by via label' do
      expect(graph.dependents_of('A', via: :belongs_to)).to contain_exactly('B')
      expect(graph.dependents_of('A', via: :redirect_to)).to be_empty
    end
  end

  describe '#affected_by on a cyclic graph' do
    before do
      graph.register(make_unit(
                       type: :model, identifier: 'A',
                       file_path: 'app/models/a.rb',
                       dependencies: [{ type: :model, target: 'B', via: :belongs_to }]
                     ))
      graph.register(make_unit(
                       type: :model, identifier: 'B',
                       file_path: 'app/models/b.rb',
                       dependencies: [{ type: :model, target: 'A', via: :belongs_to }]
                     ))
    end

    it 'terminates and does not infinite-loop on a cycle' do
      # Should complete without raising SystemStackError or hanging
      result = nil
      expect { result = graph.affected_by(['app/models/a.rb']) }.not_to raise_error
      expect(result).to be_an(Array)
    end

    it 'returns both nodes of the cycle as affected' do
      affected = graph.affected_by(['app/models/a.rb'])
      expect(affected).to include('A', 'B')
    end

    it 'visited tracking prevents duplicate queue entries' do
      # Build a 3-node cycle A → B → C → A
      graph.register(make_unit(
                       type: :model, identifier: 'C',
                       file_path: 'app/models/c.rb',
                       dependencies: [{ type: :model, target: 'A', via: :belongs_to }]
                     ))

      affected = graph.affected_by(['app/models/a.rb'])
      # Each node appears exactly once
      expect(affected.uniq).to eq(affected)
      expect(affected).to include('A', 'B', 'C')
    end
  end

  describe '#pagerank on a cyclic graph' do
    before { register_ab_cycle }

    it 'converges without raising (no NaN or Infinity scores)' do
      scores = nil
      expect { scores = graph.pagerank }.not_to raise_error

      scores.each_value do |v|
        expect(v).to be_finite
        expect(v).not_to be_nan
      end
    end

    it 'produces stable values (running twice gives the same result)' do
      run1 = graph.pagerank
      run2 = graph.pagerank
      expect(run1).to eq(run2)
    end

    it 'scores sum approximately to 1.0 on a cyclic graph' do
      total = graph.pagerank.values.sum
      expect(total).to be_within(0.01).of(1.0)
    end

    it 'assigns equal scores to symmetric nodes in a mutual cycle' do
      scores = graph.pagerank
      # A and B are symmetric — each depends on the other exactly once
      expect(scores['A']).to be_within(0.001).of(scores['B'])
    end
  end
end
