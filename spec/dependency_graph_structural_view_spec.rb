# frozen_string_literal: true

require 'spec_helper'
require 'woods/dependency_graph'
require 'woods/graph_analyzer'

# The structural view (the graph without documentation units) is built once
# and kept until the graph's structure changes.
RSpec.describe Woods::DependencyGraph, 'structural view' do
  def unit(type, identifier, dependencies: [])
    Woods::ExtractedUnit.new(type: type, identifier: identifier, file_path: "app/#{identifier}.rb").tap do |built|
      built.dependencies = dependencies
    end
  end

  let(:graph) do
    described_class.new.tap do |built|
      built.register(unit(:model, 'User'))
      built.register(unit(:service, 'Signup', dependencies: [{ type: :model, target: 'User', via: :code_reference }]))
      built.register(unit(:doc, 'docs/GUIDE.md', dependencies: [{ type: :model, target: 'User', via: :mentions }]))
    end
  end

  it 'is the graph itself when no documentation is registered' do
    plain = described_class.new.tap { |built| built.register(unit(:model, 'User')) }

    expect(plain.structural_graph).to equal(plain)
  end

  it 'is built once for a graph that does not change' do
    expect(graph.structural_graph).to equal(graph.structural_graph)
    expect(graph.structural_graph.node_exists?('docs/GUIDE.md')).to be(false)
  end

  it 'ranks the graph once for the write and the analysis that follows it' do
    allow(graph.structural_graph).to receive(:pagerank_step).and_call_original

    scores = graph.pagerank
    analysis = Woods::GraphAnalyzer.new(graph).analyze

    expect(graph.structural_graph).to have_received(:pagerank_step).exactly(20).times
    expect(scores.keys).to include('User', 'Signup', 'docs/GUIDE.md')
    expect(analysis[:domain_clusters]).to be_an(Array)
  end

  it 'is rebuilt after a unit is registered' do
    before = graph.structural_graph
    graph.register(unit(:job, 'Cleanup', dependencies: [{ type: :model, target: 'User', via: :code_reference }]))

    expect(graph.structural_graph).not_to equal(before)
    expect(graph.structural_graph.node_exists?('Cleanup')).to be(true)
    expect(graph.pagerank).to include('Cleanup')
  end

  it 'is rebuilt after a unit is removed' do
    before = graph.structural_graph
    graph.remove('Signup', type: :service)

    expect(graph.structural_graph).not_to equal(before)
    expect(graph.structural_graph.node_exists?('Signup')).to be(false)
  end

  it 'serializes an attribute annotated after the view was taken' do
    view = graph.structural_graph
    view.to_h
    graph.annotate('User', type: :model, commit_count: 7)

    expect(graph.structural_graph).to equal(view)
    expect(view.to_h.dig(:nodes, 'User', :commit_count)).to eq(7)
    expect(Woods::GraphAnalyzer.new(graph).send(:graph_nodes).dig('User', :commit_count)).to eq(7)
  end

  it 'gives a view of the same content as one built afresh' do
    graph.pagerank
    graph.annotate('Signup', type: :service, lines: 12)
    kept = graph.structural_graph.to_h
    graph.instance_variable_set(:@structural_graph, nil)

    expect(kept).to eq(graph.structural_graph.to_h)
  end
end
