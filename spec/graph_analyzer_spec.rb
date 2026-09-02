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

  describe '#domain_clusters' do
    it 'groups namespaced units into clusters' do
      graph.register(make_unit(type: :model, identifier: 'Order::Item'))
      graph.register(make_unit(type: :model, identifier: 'Order::Payment'))
      graph.register(make_unit(type: :model, identifier: 'Order::Refund'))
      graph.register(make_unit(type: :model, identifier: 'Shipping::Label'))
      graph.register(make_unit(type: :model, identifier: 'Shipping::Rate'))
      graph.register(make_unit(type: :model, identifier: 'Shipping::Carrier'))

      clusters = analyzer.domain_clusters(min_size: 2)
      names = clusters.map { |c| c[:name] }

      expect(names).to contain_exactly('Order', 'Shipping')
    end

    it 'returns enriched cluster hashes with expected keys' do
      graph.register(make_unit(type: :model, identifier: 'Order::Item'))
      graph.register(make_unit(type: :model, identifier: 'Order::Payment'))
      graph.register(make_unit(type: :model, identifier: 'Order::Refund'))

      clusters = analyzer.domain_clusters(min_size: 2)
      cluster = clusters.first

      expect(cluster).to have_key(:name)
      expect(cluster).to have_key(:hub)
      expect(cluster).to have_key(:members)
      expect(cluster).to have_key(:member_count)
      expect(cluster).to have_key(:entry_points)
      expect(cluster).to have_key(:boundary_edges)
      expect(cluster).to have_key(:types)
      expect(cluster).not_to have_key(:member_set)
    end

    it 'assigns unnamespaced units to their most-connected cluster' do
      graph.register(make_unit(type: :model, identifier: 'Order::Item'))
      graph.register(make_unit(type: :model, identifier: 'Order::Payment'))
      graph.register(make_unit(type: :model, identifier: 'Order::Refund'))
      graph.register(make_unit(type: :service, identifier: 'Checkout',
                               dependencies: [{ type: :model, target: 'Order::Item' },
                                              { type: :model, target: 'Order::Payment' }]))

      clusters = analyzer.domain_clusters(min_size: 2)
      order_cluster = clusters.find { |c| c[:name] == 'Order' }

      expect(order_cluster[:members]).to include('Checkout')
    end

    it 'filters by types when specified' do
      graph.register(make_unit(type: :model, identifier: 'Order::Item'))
      graph.register(make_unit(type: :service, identifier: 'Order::Sync'))
      graph.register(make_unit(type: :model, identifier: 'Order::Payment'))

      clusters = analyzer.domain_clusters(min_size: 2, types: ['model'])
      order_cluster = clusters.find { |c| c[:name] == 'Order' }

      expect(order_cluster[:members]).to contain_exactly('Order::Item', 'Order::Payment')
    end

    it 'returns empty for empty graph' do
      expect(analyzer.domain_clusters).to eq([])
    end

    it 'preserves disconnected small clusters when no merge target exists' do
      # Two disconnected components, both below min_size
      graph.register(make_unit(type: :model, identifier: 'Alpha::One'))
      graph.register(make_unit(type: :model, identifier: 'Beta::One'))

      clusters = analyzer.domain_clusters(min_size: 3)
      names = clusters.map { |c| c[:name] }

      # Both should survive — neither should be silently dropped
      expect(names).to contain_exactly('Alpha', 'Beta')
    end

    it 'merges small clusters into connected neighbors' do
      graph.register(make_unit(type: :model, identifier: 'Order::Item'))
      graph.register(make_unit(type: :model, identifier: 'Order::Payment'))
      graph.register(make_unit(type: :model, identifier: 'Order::Refund'))
      graph.register(make_unit(type: :model, identifier: 'Tax::Calculator',
                               dependencies: [{ type: :model, target: 'Order::Item' }]))

      clusters = analyzer.domain_clusters(min_size: 2)
      names = clusters.map { |c| c[:name] }

      # Tax has only 1 member but connects to Order, so it should merge
      expect(names).to include('Order')
      expect(names).not_to include('Tax')
    end

    it 'sorts clusters by member count descending' do
      graph.register(make_unit(type: :model, identifier: 'Small::One'))
      graph.register(make_unit(type: :model, identifier: 'Small::Two'))
      graph.register(make_unit(type: :model, identifier: 'Big::One'))
      graph.register(make_unit(type: :model, identifier: 'Big::Two'))
      graph.register(make_unit(type: :model, identifier: 'Big::Three'))

      clusters = analyzer.domain_clusters(min_size: 2)
      counts = clusters.map { |c| c[:member_count] }

      expect(counts).to eq(counts.sort.reverse)
    end
  end

  # The claim CLAUDE.md and docs/INCREMENTAL_EXTRACTION.md both make: two
  # extractions of the same tree publish the same analysis. It has to be tested
  # here, not in the differential harness — the harness compares a full run
  # against an incremental one, and until this was written its oracle sorted
  # both sides before comparing, so registration-order dependence was invisible
  # to the only test that could have seen it.
  #
  # Registration order is exactly what differs between the two paths in
  # practice: a full run interleaves by extractor, an incremental one appends
  # whatever it just touched.
  describe 'determinism across registration order' do
    let(:units) do
      [
        { type: :model, identifier: 'User' },
        { type: :model, identifier: 'Order', dependencies: [{ type: :model, target: 'User' }] },
        { type: :model, identifier: 'Invoice', dependencies: [{ type: :model, target: 'Order' }] },
        { type: :service, identifier: 'Loop::A', dependencies: [{ type: :service, target: 'Loop::B' }] },
        { type: :service, identifier: 'Loop::B', dependencies: [{ type: :service, target: 'Loop::A' }] },
        { type: :service, identifier: 'Detached' },
        { type: :controller, identifier: 'OrdersController', dependencies: [{ type: :model, target: 'Order' }] }
      ]
    end

    def analysis_for(units)
      built = Woods::DependencyGraph.new
      units.each { |attrs| built.register(make_unit(**attrs)) }
      described_class.new(built).analyze
    end

    it 'produces byte-identical analysis whatever order units were registered in' do
      forward = analysis_for(units)

      units.each_index do |offset|
        rotated = units.rotate(offset)
        expect(analysis_for(rotated)).to(
          eq(forward),
          "registering from index #{offset} changed the analysis — it is not a pure function of graph content"
        )
      end

      expect(analysis_for(units.reverse)).to eq(forward)
    end

    # #216 / B-103. domain_clusters is not part of analyze(), so the rotation
    # above could never see it — and it was the one analyzer output still
    # decided by registration order: max_by/min_by tie-breaks picked whichever
    # equal-scoring cluster the hash happened to enumerate first, and members,
    # entry points and boundary edges were emitted in graph order.
    describe 'domain_clusters' do
      # Deliberately tie-heavy: two same-size namespaces whose members have
      # identical connectivity, so every tie-break in the path is exercised.
      let(:cluster_units) do
        [
          { type: :model, identifier: 'Billing::Invoice', dependencies: [{ type: :model, target: 'Shared::Money' }] },
          { type: :model, identifier: 'Billing::Payment', dependencies: [{ type: :model, target: 'Shared::Money' }] },
          { type: :model, identifier: 'Billing::Refund', dependencies: [{ type: :model, target: 'Shared::Money' }] },
          { type: :model, identifier: 'Catalog::Item', dependencies: [{ type: :model, target: 'Shared::Money' }] },
          { type: :model, identifier: 'Catalog::Price', dependencies: [{ type: :model, target: 'Shared::Money' }] },
          { type: :model, identifier: 'Catalog::Stock', dependencies: [{ type: :model, target: 'Shared::Money' }] },
          { type: :model, identifier: 'Shared::Money' },
          { type: :model, identifier: 'Shared::Currency' },
          { type: :model, identifier: 'Shared::Rate' },
          # EXTB-7. Unnamespaced units are assigned to their most-connected
          # cluster, and each assignment used to mutate the cluster before the
          # next unit was scored. `Standalone1`'s only edge is to another
          # unnamespaced unit, so it joined Billing only when `Standalone2`
          # happened to be registered (and assigned) first — the fixture had no
          # such chain, so the rotation assertion could not see it.
          { type: :model, identifier: 'Standalone1',
            dependencies: [{ type: :model, target: 'Standalone2' }] },
          { type: :model, identifier: 'Standalone2',
            dependencies: [{ type: :model, target: 'Billing::Invoice' }] }
        ]
      end

      def clusters_for(units)
        built = Woods::DependencyGraph.new
        units.each { |attrs| built.register(make_unit(**attrs)) }
        described_class.new(built).domain_clusters(min_size: 2)
      end

      it 'produces identical clusters whatever order units were registered in' do
        forward = clusters_for(cluster_units)

        expect(forward).not_to be_empty

        cluster_units.each_index do |offset|
          expect(clusters_for(cluster_units.rotate(offset))).to(
            eq(forward),
            "registering from index #{offset} changed the clusters — they are not a pure function of graph content"
          )
        end

        expect(clusters_for(cluster_units.reverse)).to eq(forward)
      end

      it 'sorts members, entry points and boundary edges' do
        clusters_for(cluster_units).each do |cluster|
          expect(cluster[:members]).to eq(cluster[:members].sort)
          expect(cluster[:entry_points]).to eq(cluster[:entry_points].sort)
          boundary_keys = cluster[:boundary_edges].map { |e| [e[:from].to_s, e[:to].to_s] }
          expect(boundary_keys).to eq(boundary_keys.sort)
        end
      end
    end
  end
end
