# frozen_string_literal: true

require 'spec_helper'
require 'woods/mcp/traversal_evidence'
require 'woods/mcp/traversal_evidence_text'

RSpec.describe Woods::MCP::TraversalEvidence do
  def graph
    {
      'nodes' => { 'A' => { 'type' => 'model' }, 'B' => { 'type' => 'model' }, 'C' => { 'type' => 'service' } },
      'edges' => { 'A' => [{ 'target' => 'B', 'via' => 'belongs_to' }, { 'target' => 'B', 'via' => 'calls' }],
                   'B' => [{ 'target' => 'C', 'via' => 'calls' }], 'C' => [{ 'target' => 'A', 'via' => 'calls' }] },
      'reverse' => { 'B' => ['A'], 'C' => ['B'], 'A' => ['C'] }
    }
  end

  def walk(data = graph, root: 'A', **options)
    index = Woods::MCP::TraversalEvidenceIndex.new(data)
    described_class.new(index).call(root, depth: 3, direction: :forward, **options)
  end

  it 'keeps distinct recorded relationships and one bounded shortest witness per node through cycles' do
    result = walk
    expect(result[:nodes].keys).to eq(%w[A B C])
    explanation = result.fetch(:explanation)
    expect(explanation[:edges].values.map { |edge| edge[:via] }).to eq(%w[belongs_to calls calls calls])
    expect(explanation[:witnesses]['B']).to include(parent: 'A', impact: 'direct', typed_path_complete: true)
    expect(explanation[:witnesses]['C']).to include(parent: 'B', impact: 'transitive', typed_path_complete: true)
    expect(explanation[:witnesses].size).to eq(3)
  end

  it 'retains original source-to-target direction during reverse traversal' do
    result = walk(root: 'B', direction: :reverse, depth: 1)
    edges = result[:explanation][:edges].values
    source = { identifier: 'A', type: 'model' }
    target = { identifier: 'B', type: 'model' }
    expect(edges.map { |edge| [edge[:source], edge[:target], edge[:via]] }).to eq(
      [[source, target, 'belongs_to'], [source, target, 'calls']]
    )
    expect(result[:explanation][:witnesses]['A']).to include(parent: 'B', impact: 'direct')
  end

  # The rule: an explained edge says how Woods knows it, read by the type of
  # the unit the edge leaves, in either traversal direction.
  describe 'edge evidence' do
    def evidence_graph
      { 'nodes' => { 'Auditable' => { 'type' => 'concern' }, 'Order' => { 'type' => 'model' },
                     'Trackable' => { 'type' => 'concern' }, 'OrdersController' => { 'type' => 'controller' } },
        'edges' => { 'Order' => [{ 'target' => 'Auditable', 'via' => 'include' }],
                     'Trackable' => [{ 'target' => 'Auditable', 'via' => 'include' }],
                     'OrdersController' => [{ 'target' => 'Order', 'via' => 'code_reference' },
                                            { 'target' => 'Order', 'via' => 'teleports_to' }, 'Auditable'] },
        'reverse' => { 'Auditable' => %w[Order Trackable OrdersController], 'Order' => ['OrdersController'] } }
    end

    def evidence_by_edge(result)
      result[:explanation][:edges].values.to_h do |edge|
        [[edge[:source][:identifier], edge[:via]], edge.slice(:evidence, :evidence_mixed)]
      end
    end

    it 'classifies each forward edge, marks a floor, and leaves the unlisted and the unlabelled unknown' do
      edges = evidence_by_edge(walk(evidence_graph, root: 'OrdersController', depth: 2))

      expect(edges).to eq(
        %w[OrdersController code_reference] => { evidence: 'static', evidence_mixed: true },
        %w[OrdersController teleports_to] => { evidence: 'unknown' },
        ['OrdersController', nil] => { evidence: 'unknown' },
        %w[Order include] => { evidence: 'verified', evidence_mixed: true }
      )
    end

    it 'classifies a dependents row by the unit the edge leaves, not the unit asked about' do
      edges = evidence_by_edge(walk(evidence_graph, root: 'Auditable', direction: :reverse, depth: 1))

      expect(edges).to include(%w[Order include] => { evidence: 'verified', evidence_mixed: true },
                               %w[Trackable include] => { evidence: 'static', evidence_mixed: true })
    end

    it 'reads the source type a reverse_via record states' do
      data = evidence_graph.merge(
        'reverse_via' => { 'Auditable' => [{ 'source' => 'Order', 'source_type' => 'model', 'via' => 'include' },
                                           { 'source' => 'Trackable', 'source_type' => 'concern',
                                             'via' => 'include' }] }
      )
      edges = evidence_by_edge(walk(data, root: 'Auditable', direction: :reverse, depth: 1))

      expect(edges).to eq(%w[Order include] => { evidence: 'verified', evidence_mixed: true },
                          %w[Trackable include] => { evidence: 'static', evidence_mixed: true })
    end

    it 'is unknown for an edge whose source has no recorded type' do
      data = { 'nodes' => { 'A' => {}, 'B' => { 'type' => 'model' } },
               'edges' => { 'A' => [{ 'target' => 'B', 'via' => 'belongs_to' }] }, 'reverse' => { 'B' => ['A'] } }

      expect(evidence_by_edge(walk(data, depth: 1))).to eq(%w[A belongs_to] => { evidence: 'unknown' })
    end

    it 'renders the attribute after the recorded ones, with one line that defines the classes' do
      text = Woods::MCP::TraversalEvidenceText.lines(
        walk(evidence_graph, root: 'OrdersController', depth: 2)[:explanation]
      )

      expect(text).to include(
        'e0: OrdersController (controller) -> Order (model); via=code_reference; through=unknown; ' \
        'through_db=unknown; disable_joins=unknown; evidence=at least static',
        'e3: Order (model) -> Auditable (concern); via=include; through=unknown; through_db=unknown; ' \
        'disable_joins=unknown; evidence=at least verified'
      )
      expect(text.grep(/evidence=unknown\z/).size).to eq(2)
      expect(text).to include("Evidence: #{Woods::EdgeEvidence::LEGEND} unknown = no classification in this " \
                              'build. None means the code runs.')
    end
  end

  it 'never guesses target types across a primary/variant collision' do
    data = graph
    data['variants'] =
      [{ 'identifier' => 'B', 'type' => 'controller', 'edges' => [{ 'target' => 'C', 'via' => 'renders' }] }]
    result = walk(data)
    target = result[:explanation][:edges].values.first[:target]
    expect(target).to eq(identifier: 'B', type: nil, candidate_types: %w[controller model], resolution: 'ambiguous')
    expect(result[:explanation][:edges].values.map do |edge|
      edge[:source]
    end).to include(identifier: 'B', type: 'controller')
    expect(result[:explanation][:witnesses]['C'][:typed_path_complete]).to be(false)
  end

  it 'preserves unknown legacy attributes and unresolved targets without inventing evidence' do
    data = graph
    data['edges']['A'] = ['Outside']
    result = walk(data, depth: 1)
    expect(result[:explanation][:edges].values.first).to include(
      source: { identifier: 'A', type: 'model' },
      target: { identifier: 'Outside', type: nil, candidate_types: [], resolution: 'unresolved' },
      via: nil, through: nil, through_db: nil, disable_joins: nil, evidence: 'unknown'
    )
  end

  it 'charges legacy reverse adjacency and each inspected forward edge before filtering' do
    result = walk(root: 'B', direction: :reverse, via: ['calls'], max_edges: 2)
    expect(result).to include(partial: true, partial_reason: 'edge_budget')
    expect(result[:traversal_budget][:visited_edges]).to eq(2)
    expect(result[:explanation][:edges]).to be_empty
  end

  it 'uses reverse_via without scanning unrelated forward adjacency' do
    data = graph
    data['reverse_via'] = { 'B' => [{ 'source' => 'A', 'source_type' => 'model', 'via' => 'belongs_to',
                                      'through' => 'links', 'through_db' => 'archive', 'disable_joins' => true }] }
    data['edges']['A'] = Object.new
    result = walk(data, root: 'B', direction: :reverse, depth: 1, max_edges: 1)
    expect(result).not_to have_key(:partial)
    expect(result[:explanation][:edges].values.first).to include(through: 'links', through_db: 'archive',
                                                                 disable_joins: true)
  end

  it 'keeps one shortest witness in a diamond and includes required ancestors on a later page' do
    data = graph
    data['nodes']['D'] = { 'type' => 'model' }
    data['edges']['A'] << { 'target' => 'D', 'via' => 'calls' }
    data['edges']['D'] = [{ 'target' => 'C', 'via' => 'calls' }]
    result = walk(data)
    expect(result[:explanation][:witnesses]['C'][:parent]).to eq('B')
    result[:nodes] = result[:nodes].slice('C')
    Woods::MCP::TraversalEvidencePage.apply(result)
    witnesses = result[:explanation][:witnesses]
    expect(witnesses.keys).to eq(%w[A B C])
    expect(witnesses['A'][:context]).to be(true)
    expect(witnesses['B'][:context]).to be(true)
    expect(witnesses['C'][:context]).to be(false)
    expect(result[:explanation][:edges].values).not_to include(hash_including(source: { identifier: 'D',
                                                                                        type: 'model' }))
  end

  it 'returns no unrelated explanation records for an empty page while preserving partial metadata' do
    result = walk(max_nodes: 1)
    result[:nodes] = {}
    Woods::MCP::TraversalEvidencePage.apply(result)
    expect(result[:explanation][:edges]).to be_empty
    expect(result[:explanation][:witnesses]).to be_empty
    expect(result).to include(partial: true, partial_reason: 'node_budget')
  end

  it 'finishes exactly at the edge budget without claiming truncation unless another edge is examined' do
    result = walk(depth: 1, max_edges: 2)
    expect(result).not_to have_key(:partial)
    expect(result[:explanation][:edges].size).to eq(2)
    expect(walk(depth: 1, max_edges: 1)).to include(partial: true, partial_reason: 'edge_budget')
  end

  it 'does not publish edges to a neighbor that the node budget prevented admitting' do
    result = walk(max_nodes: 1)
    expect(result[:nodes].keys).to eq(['A'])
    expect(result[:nodes]['A'][:deps]).to be_empty
    expect(result[:explanation][:edges]).to be_empty
    expect(result[:traversal_budget]).to include(visited_nodes: 1, visited_edges: 1)
  end

  it 'charges candidates excluded by type and via filters and stops without visiting later records' do
    data = graph
    data['edges']['A'] << Object.new
    result = walk(data, types: ['service'], via: ['calls'], max_edges: 2)
    expect(result[:nodes].keys).to eq(['A'])
    expect(result).to include(partial: true, partial_reason: 'edge_budget')
    expect(result[:traversal_budget][:visited_edges]).to eq(2)
  end

  it 'keeps depth zero as the root alone, and does not retain mutable state between calls' do
    walker = described_class.new(Woods::MCP::TraversalEvidenceIndex.new(graph))
    first = walker.call('A', depth: 0)
    expect(first[:nodes].keys).to eq(['A'])
    expect(first[:explanation][:edges]).to be_empty
    expect(walker.call('B', depth: 1)[:nodes].keys).to eq(%w[B C])
    expect(first[:nodes].keys).to eq(['A'])
  end

  it 'deduplicates identical evidence while charging every stored duplicate' do
    data = graph
    data['edges']['A'] = [data['edges']['A'].first] * 3
    result = walk(data, depth: 1, max_edges: 2)
    expect(result).to include(partial: true, partial_reason: 'edge_budget')
    expect(result[:nodes]['A'][:deps]).to eq(['B'])
    expect(result[:explanation][:edges].size).to eq(1)
  end

  it 'marks an ambiguous starting identity and its downstream witnesses as incompletely typed' do
    data = graph
    data['variants'] = [{ 'identifier' => 'A', 'type' => 'controller', 'edges' => [] }]
    result = walk(data)
    expect(result[:explanation][:root]).to include(resolution: 'ambiguous', candidate_types: %w[controller model])
    expect(result[:explanation][:witnesses].values.map { |witness| witness[:typed_path_complete] }.uniq).to eq([false])
  end

  it 'retains identifier-level type filtering without changing the recorded variant source type' do
    data = graph
    data['edges']['A'] = []
    data['variants'] = [{ 'identifier' => 'A', 'type' => 'controller',
                          'edges' => [{ 'target' => 'B', 'via' => 'calls' }] }]
    result = walk(data, root: 'B', direction: :reverse, depth: 1, types: ['model'])
    expect(result[:nodes].keys).to eq(%w[B A])
    expect(result[:explanation][:edges].values.first[:source]).to eq(identifier: 'A', type: 'controller')
    expect(result[:explanation][:witnesses]['A'][:typed_path_complete]).to be(false)
  end
end
