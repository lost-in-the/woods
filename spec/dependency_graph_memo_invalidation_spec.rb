# frozen_string_literal: true

require 'spec_helper'
require 'woods/dependency_graph'

# The rule: every public mutation of the graph invalidates every value derived
# from it. Each mutator runs on a graph whose memos are warm and on one whose
# memos were never built; afterwards both must answer alike.
RSpec.describe Woods::DependencyGraph, 'memo invalidation' do
  def unit(type, identifier, dependencies: [])
    path = "app/#{identifier.gsub('::', '/').downcase}.rb"
    Woods::ExtractedUnit.new(type: type, identifier: identifier, file_path: path).tap do |built|
      built.dependencies = dependencies
    end
  end

  def edge(target, via, type: :model)
    { type: type, target: target, via: via }
  end

  def build
    described_class.new.tap do |graph|
      graph.register(unit(:model, 'Shop::Account'))
      graph.register(unit(:model, 'Shop::Ledger', dependencies: [edge('Shop::Account', :belongs_to)]))
      charges = [edge('Shop::Ledger', :code_reference), edge('Shop::Account', :code_reference)]
      graph.register(unit(:service, 'Billing::Charge', dependencies: charges))
      graph.register(unit(:job, 'Billing::Retry', dependencies: [edge('Billing::Charge', :service_call)]))
      graph.register(unit(:factory, 'Shop::Ledger', dependencies: [edge('Shop::Ledger', :factory_for)]))
      graph.register(unit(:doc, 'docs/billing.md', dependencies: [edge('Billing::Charge', :documents)]))
    end
  end

  # Every value the graph memoizes, read through its public surface.
  def derived(graph)
    structural = graph.structural_graph
    {
      to_h: graph.to_h,
      pagerank: graph.pagerank,
      pagerank_tuned: graph.pagerank(damping: 0.5, iterations: 5),
      suffix_names: graph.suffix_names,
      suffixes: graph.suffix_names.to_h { |name| [name, graph.find_all_by_suffix(name)] },
      first_by_suffix: graph.find_node_by_suffix('Ledger'),
      structural_to_h: structural.to_h,
      structural_pagerank: structural.pagerank
    }
  end

  mutations = {
    'register a new unit' => ->(g) { g.register(unit(:model, 'Billing::Account')) },
    'register over an existing unit with other edges' =>
      ->(g) { g.register(unit(:service, 'Billing::Charge', dependencies: [edge('Billing::Retry', :job_enqueue)])) },
    'register a documentation unit' =>
      ->(g) { g.register(unit(:doc, 'docs/shop.md', dependencies: [edge('Shop::Account', :documents)])) },
    'remove one type' => ->(g) { g.remove('Shop::Ledger', type: :factory) },
    'remove every type' => ->(g) { g.remove('Shop::Ledger') },
    'remove a documentation unit' => ->(g) { g.remove('docs/billing.md') },
    'unregister one type' => ->(g) { g.unregister('Billing::Charge', type: :service) },
    'unregister every type' => ->(g) { g.unregister('Shop::Ledger') },
    'annotate a node' => ->(g) { g.annotate('Shop::Account', type: :model, lines: 12, loc: 10) },
    'annotate a node away' => lambda { |g|
      g.annotate('Shop::Account', type: :model, lines: 12)
      g.annotate('Shop::Account', type: :model, lines: nil)
    }
  }

  mutations.each do |name, mutate|
    it "recomputes every derived value after: #{name}" do
      warm = build
      derived(warm)
      instance_exec(warm, &mutate)

      cold = build
      instance_exec(cold, &mutate)

      expect(derived(warm)).to eq(derived(cold))
    end
  end

  it 'keeps PageRank bit-identical for a graph that does not change' do
    warm = build
    first = warm.pagerank

    expect(warm.pagerank).to eq(first)
    expect(build.pagerank).to eq(first)
    expect(warm.pagerank.values.map { |score| [score].pack('G') }).to eq(first.values.map { |score| [score].pack('G') })
  end
end
