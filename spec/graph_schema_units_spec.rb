# frozen_string_literal: true

require 'spec_helper'

# Table and external-consumer units describe the database, not application
# code. They take edges from every migration and model, so ranking them would
# reorder the code the rankings exist to describe.
RSpec.describe 'Schema units in graph analysis' do
  include_context 'isolated Woods runtime'

  let(:graph) { Woods::DependencyGraph.new }
  let(:analyzer) { Woods::GraphAnalyzer.new(graph) }

  def unit(type, identifier, dependencies: [], metadata: {})
    built = Woods::ExtractedUnit.new(type: type, identifier: identifier, file_path: nil)
    built.dependencies = dependencies
    built.metadata = metadata
    built
  end

  def code_units
    [unit(:model, 'Widget'),
     unit(:service, 'WidgetService', dependencies: [{ type: :model, target: 'Widget', via: :code_reference }]),
     unit(:migration, 'CreateWidgets', dependencies: [{ type: :model, target: 'Widget', via: :table_name }])]
  end

  def with_schema_units
    [unit(:model, 'Widget', dependencies: [{ type: :database_table, target: 'table:widgets', via: :table }]),
     unit(:service, 'WidgetService', dependencies: [{ type: :model, target: 'Widget', via: :code_reference }]),
     unit(:migration, 'CreateWidgets',
          dependencies: [{ type: :database_table, target: 'table:widgets', via: :migrates },
                         { type: :model, target: 'Widget', via: :table_name },
                         { type: :database_table, target: 'table:ledger_entries', via: :migrates }]),
     unit(:database_table, 'table:widgets', metadata: { database: 'primary' }),
     unit(:database_table, 'table:ledger_entries',
          dependencies: [{ type: :database_table, target: 'table:widgets', via: :foreign_key }],
          metadata: { database: 'primary', foreign_keys: [{ to_table: 'widgets' }] }),
     unit(:external_consumer, 'external:storefront',
          dependencies: [{ type: :database_table, target: 'table:widgets', via: :reads_table }])]
  end

  describe 'DependencyGraph#pagerank' do
    it 'scores code units exactly as a graph without schema units does' do
      baseline = Woods::DependencyGraph.new
      code_units.each { |built| baseline.register(built) }
      with_schema_units.each { |built| graph.register(built) }

      expect(graph.pagerank.slice('Widget', 'WidgetService', 'CreateWidgets')).to eq(baseline.pagerank)
    end

    it 'gives schema units a score of zero, so every node still has one' do
      with_schema_units.each { |built| graph.register(built) }

      scores = graph.pagerank

      expect(scores.values_at('table:widgets', 'table:ledger_entries', 'external:storefront')).to eq([0.0, 0.0, 0.0])
      expect(scores.values.sum).to be_within(1e-9).of(1.0)
    end

    it 'scores a graph of schema units only at zero' do
      graph.register(unit(:database_table, 'table:widgets'))

      expect(graph.pagerank).to eq('table:widgets' => 0.0)
    end
  end

  describe 'GraphAnalyzer' do
    before { with_schema_units.each { |built| graph.register(built) } }

    it 'keeps schema units out of the hub list' do
      expect(analyzer.hubs.map { |hub| hub[:identifier] }).to contain_exactly('Widget', 'WidgetService',
                                                                              'CreateWidgets')
    end

    it 'keeps schema units out of orphans and dead ends' do
      expect(analyzer.orphans).to contain_exactly('WidgetService', 'CreateWidgets')
      expect(analyzer.dead_ends).to eq([])
    end

    it 'does not report a table foreign key as a cross-database edge' do
      graph.register(unit(:model, 'Widget', metadata: { database: 'billing', table_name: 'widgets' },
                                            dependencies: [{ type: :database_table, target: 'table:widgets',
                                                             via: :table }]))

      expect(analyzer.cross_database_edges).to eq([])
    end

    it 'lists the tables no model reads, sorted' do
      graph.register(unit(:database_table, 'table:audit_rows'))

      expect(analyzer.unmodelled_tables).to eq(%w[table:audit_rows table:ledger_entries])
    end

    it 'publishes unmodelled tables and their count in the analysis report' do
      report = analyzer.analyze

      expect(report[:unmodelled_tables]).to eq(['table:ledger_entries'])
      expect(report[:stats][:unmodelled_table_count]).to eq(1)
    end
  end
end
