# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Woods::GraphAnalyzer do
  let(:graph) { Woods::DependencyGraph.new }
  let(:analyzer) { described_class.new(graph) }

  def make_unit(type:, identifier:, file_path: nil, dependencies: [])
    unit = Woods::ExtractedUnit.new(
      type: type,
      identifier: identifier,
      file_path: file_path || "/app/#{identifier.underscore}.rb"
    )
    unit.dependencies = dependencies
    unit
  end

  describe '#orphans' do
    it 'returns units with no dependents' do
      graph.register(make_unit(type: :model, identifier: 'User'))
      graph.register(make_unit(type: :model, identifier: 'Order',
                               dependencies: [{ type: :model, target: 'User' }]))

      # User has a dependent (Order), Order has none
      expect(analyzer.orphans).to include('Order')
      expect(analyzer.orphans).not_to include('User')
    end

    it 'excludes rails_source and gem_source types' do
      graph.register(make_unit(type: :rails_source, identifier: 'rails/activerecord/callbacks'))
      graph.register(make_unit(type: :gem_source, identifier: 'gems/devise/models'))

      expect(analyzer.orphans).not_to include('rails/activerecord/callbacks')
      expect(analyzer.orphans).not_to include('gems/devise/models')
    end

    it 'returns empty for empty graph' do
      expect(analyzer.orphans).to eq([])
    end
  end

  describe '#dead_ends' do
    it 'returns units with no dependencies' do
      graph.register(make_unit(type: :model, identifier: 'User'))
      graph.register(make_unit(type: :model, identifier: 'Order',
                               dependencies: [{ type: :model, target: 'User' }]))

      expect(analyzer.dead_ends).to include('User')
      expect(analyzer.dead_ends).not_to include('Order')
    end
  end

  describe '#hubs' do
    it 'returns units sorted by dependent count' do
      graph.register(make_unit(type: :model, identifier: 'User'))
      graph.register(make_unit(type: :model, identifier: 'Order',
                               dependencies: [{ type: :model, target: 'User' }]))
      graph.register(make_unit(type: :service, identifier: 'UserService',
                               dependencies: [{ type: :model, target: 'User' }]))
      graph.register(make_unit(type: :controller, identifier: 'UsersController',
                               dependencies: [{ type: :model, target: 'User' }]))
      graph.register(make_unit(type: :model, identifier: 'Product'))

      hubs = analyzer.hubs(limit: 3)
      expect(hubs.first[:identifier]).to eq('User')
      expect(hubs.first[:dependent_count]).to eq(3)
    end

    it 'respects the limit parameter' do
      5.times do |i|
        graph.register(make_unit(type: :model, identifier: "Model#{i}"))
      end

      expect(analyzer.hubs(limit: 2).size).to eq(2)
    end
  end

  describe '#cycles' do
    it 'detects a simple cycle' do
      graph.register(make_unit(type: :model, identifier: 'A',
                               dependencies: [{ type: :model, target: 'B' }]))
      graph.register(make_unit(type: :model, identifier: 'B',
                               dependencies: [{ type: :model, target: 'A' }]))

      expect(analyzer.cycles).not_to be_empty
      cycle = analyzer.cycles.first
      expect(cycle).to include('A')
      expect(cycle).to include('B')
      # Cycle should end with the same node it starts with
      expect(cycle.first).to eq(cycle.last)
    end

    it 'detects a 3-node cycle' do
      graph.register(make_unit(type: :model, identifier: 'A',
                               dependencies: [{ type: :model, target: 'B' }]))
      graph.register(make_unit(type: :model, identifier: 'B',
                               dependencies: [{ type: :model, target: 'C' }]))
      graph.register(make_unit(type: :model, identifier: 'C',
                               dependencies: [{ type: :model, target: 'A' }]))

      expect(analyzer.cycles.size).to eq(1)
      cycle = analyzer.cycles.first
      expect(cycle.size).to eq(4) # A -> B -> C -> A
    end

    it 'returns empty for acyclic graph' do
      graph.register(make_unit(type: :model, identifier: 'A',
                               dependencies: [{ type: :model, target: 'B' }]))
      graph.register(make_unit(type: :model, identifier: 'B',
                               dependencies: [{ type: :model, target: 'C' }]))
      graph.register(make_unit(type: :model, identifier: 'C'))

      expect(analyzer.cycles).to be_empty
    end

    it 'returns empty for empty graph' do
      expect(analyzer.cycles).to eq([])
    end

    it 'deduplicates rotated cycles' do
      # A -> B -> C -> A is same cycle as B -> C -> A -> B
      graph.register(make_unit(type: :model, identifier: 'A',
                               dependencies: [{ type: :model, target: 'B' }]))
      graph.register(make_unit(type: :model, identifier: 'B',
                               dependencies: [{ type: :model, target: 'C' }]))
      graph.register(make_unit(type: :model, identifier: 'C',
                               dependencies: [{ type: :model, target: 'A' }]))

      # Should only find one cycle, not three
      expect(analyzer.cycles.size).to eq(1)
    end
  end

  describe '#bridges' do
    it 'identifies nodes on many shortest paths' do
      # A -> B -> C -> D (B and C are bridges)
      graph.register(make_unit(type: :model, identifier: 'A',
                               dependencies: [{ type: :model, target: 'B' }]))
      graph.register(make_unit(type: :model, identifier: 'B',
                               dependencies: [{ type: :model, target: 'C' }]))
      graph.register(make_unit(type: :model, identifier: 'C',
                               dependencies: [{ type: :model, target: 'D' }]))
      graph.register(make_unit(type: :model, identifier: 'D'))

      bridges = analyzer.bridges(limit: 5, sample_size: 50)
      bridge_ids = bridges.map { |b| b[:identifier] }

      # B and C should be bridges (on the path between A and D)
      expect(bridge_ids).to include('B')
      expect(bridge_ids).to include('C')
    end

    it 'returns empty for small graph' do
      graph.register(make_unit(type: :model, identifier: 'A'))
      expect(analyzer.bridges).to eq([])
    end
  end

  describe '#analyze' do
    before do
      graph.register(make_unit(type: :model, identifier: 'User'))
      graph.register(make_unit(type: :model, identifier: 'Order',
                               dependencies: [{ type: :model, target: 'User' }]))
    end

    it 'returns all analysis sections' do
      report = analyzer.analyze

      expect(report).to have_key(:orphans)
      expect(report).to have_key(:dead_ends)
      expect(report).to have_key(:hubs)
      expect(report).to have_key(:cycles)
      expect(report).to have_key(:bridges)
      expect(report).to have_key(:stats)
    end

    it 'includes stats with counts' do
      stats = analyzer.analyze[:stats]

      expect(stats).to have_key(:orphan_count)
      expect(stats).to have_key(:dead_end_count)
      expect(stats).to have_key(:hub_count)
      expect(stats).to have_key(:cycle_count)
    end
  end
end
