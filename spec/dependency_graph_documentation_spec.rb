# frozen_string_literal: true

require 'spec_helper'
require 'woods/extracted_unit'
require 'woods/dependency_graph'
require 'woods/graph_analyzer'

RSpec.describe 'Documentation units in the dependency graph' do
  def unit(type, identifier, path, dependencies = [])
    Woods::ExtractedUnit.new(type: type, identifier: identifier, file_path: path).tap do |extracted|
      extracted.dependencies = dependencies
    end
  end

  def code_units
    [
      unit(:model, 'Widget', '/app/app/models/widget.rb', [{ type: :model, target: 'Ledger', via: :belongs_to }]),
      unit(:model, 'Ledger', '/app/app/models/ledger.rb'),
      unit(:service, 'Widget::Importer', '/app/app/services/widget/importer.rb',
           [{ type: :model, target: 'Widget', via: :code_reference }]),
      unit(:job, 'ShipmentJob', '/app/app/jobs/shipment_job.rb',
           [{ type: :service, target: 'Widget::Importer', via: :code_reference }])
    ]
  end

  def doc_units
    [
      unit(:doc, 'docs/widgets.md', '/app/docs/widgets.md',
           [{ type: :model, target: 'Widget', via: :documents }, { type: :model, target: 'Ledger', via: :documents },
            { type: :doc, target: 'README.md', via: :doc_link }]),
      unit(:doc, 'README.md', '/app/README.md',
           [{ type: :doc, target: 'docs/widgets.md', via: :doc_link },
            { type: :job, target: 'ShipmentJob', via: :documents }]),
      unit(:doc, 'docs/orphan.md', '/app/docs/orphan.md')
    ]
  end

  def graph_of(units)
    Woods::DependencyGraph.new.tap { |graph| units.each { |extracted| graph.register(extracted) } }
  end

  let(:code_graph) { graph_of(code_units) }
  let(:graph) { graph_of(code_units + doc_units) }

  it 'names the documentation unit types' do
    expect(Woods::DependencyGraph::DOCUMENTATION_UNIT_TYPES).to eq(%i[doc])
  end

  describe '#pagerank' do
    it 'scores code units exactly as a graph without documentation does' do
      expect(graph.pagerank.slice(*code_graph.pagerank.keys)).to eq(code_graph.pagerank)
    end

    it 'scores documentation units zero' do
      expect(graph.pagerank.values_at('docs/widgets.md', 'README.md', 'docs/orphan.md')).to eq([0.0, 0.0, 0.0])
    end

    it 'is unaffected by registration order' do
      interleaved = graph_of(doc_units + code_units)

      expect(interleaved.pagerank.slice(*code_graph.pagerank.keys).transform_values { |score| score.round(12) })
        .to eq(graph_of(code_units).pagerank.transform_values { |score| score.round(12) })
    end
  end

  describe '#affected_by' do
    it 'does not walk from changed code into the documents that mention it' do
      expect(graph.affected_by(['/app/app/models/ledger.rb']))
        .to contain_exactly('Ledger', 'Widget', 'Widget::Importer', 'ShipmentJob')
    end

    it 'returns a changed document without the documents linking to it' do
      expect(graph.affected_by(['/app/README.md'])).to eq(['README.md'])
    end
  end

  it 'still lists a document as a dependent of the unit it names' do
    expect(graph.dependents_of('Widget')).to contain_exactly('Widget::Importer', 'docs/widgets.md')
    expect(graph.dependents_of('Widget', via: :documents)).to eq(['docs/widgets.md'])
  end

  it 'counts only the ranked nodes' do
    expect(graph.structural_node_count).to eq(code_graph.pagerank.size)
    expect(code_graph.structural_node_count).to eq(4)
  end

  describe '#structural_graph' do
    it 'is the graph itself when it holds no documentation' do
      expect(code_graph.structural_graph).to equal(code_graph)
    end

    it 'drops documentation nodes, edges, reverse edges and paths without changing the original' do
      structural = graph.structural_graph.to_h

      expect(structural).to eq(code_graph.to_h)
      expect(graph.units_of_type(:doc)).to contain_exactly('docs/widgets.md', 'README.md', 'docs/orphan.md')
      expect(graph.dependents_of('ShipmentJob')).to eq(['README.md'])
    end
  end

  describe Woods::GraphAnalyzer do
    it 'reports the same analysis with and without documentation' do
      expect(described_class.new(graph).analyze).to eq(described_class.new(code_graph).analyze)
    end

    it 'does not report documents as orphans, dead ends, hubs or cycles' do
      analyzer = described_class.new(graph)
      reported = analyzer.orphans + analyzer.dead_ends + analyzer.hubs.map { |hub| hub[:identifier] } +
                 analyzer.hubs.flat_map { |hub| hub[:dependents] } + analyzer.cycles.flatten

      expect(reported.grep(/\.md\z/)).to eq([])
    end
  end
end
