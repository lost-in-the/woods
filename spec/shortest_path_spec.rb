# frozen_string_literal: true

require 'spec_helper'
require 'json'

# The rule: `shortest_path` answers with one shortest chain of published
# forward edges between two typed units, the same one for the same graph
# content, and a search a bound stopped never reads as "no path exists".
RSpec.describe 'Woods::DependencyGraph#shortest_path' do
  let(:graph) { Woods::DependencyGraph.new }

  def make_unit(type, identifier, *dependencies)
    unit = Woods::ExtractedUnit.new(type: type, identifier: identifier, file_path: "/app/#{identifier}.rb")
    unit.dependencies = dependencies.map do |dependency|
      dependency.is_a?(Hash) ? dependency : { target: dependency, via: :code_reference }
    end
    unit
  end

  def register(*units, into: graph)
    units.each { |unit| into.register(unit) }
    into
  end

  def chain(result)
    result[:hops].map { |hop| [hop[:source], hop[:target]] }
  end

  describe 'a path that exists' do
    it 'answers a direct edge as one hop naming both units, their types and the via' do
      register(make_unit(:controller, 'OrdersController', { target: 'Order', via: :code_reference }),
               make_unit(:model, 'Order'))

      result = graph.shortest_path('OrdersController', 'Order')

      expect(result).to include(found: true, direction: 'forward', hop_count: 1)
      expect(result[:hops]).to eq(
        [{ source: 'OrdersController', source_type: 'controller', target: 'Order', target_type: 'model',
           via: ['code_reference'], evidence: 'static', evidence_mixed: true }]
      )
      expect(result[:from]).to eq(identifier: 'OrdersController', type: 'controller')
      expect(result[:to]).to eq(identifier: 'Order', type: 'model')
    end

    it 'follows several hops in order' do
      register(make_unit(:controller, 'A', 'B'), make_unit(:service, 'B', 'C'), make_unit(:service, 'C', 'D'),
               make_unit(:model, 'D'))

      result = graph.shortest_path('A', 'D')

      expect(result).to include(found: true, hop_count: 3)
      expect(chain(result)).to eq([%w[A B], %w[B C], %w[C D]])
    end

    it 'picks a shortest path when a longer one exists' do
      register(make_unit(:controller, 'A', 'B', 'Z'), make_unit(:service, 'B', 'C'), make_unit(:service, 'C', 'D'),
               make_unit(:service, 'Z', 'D'), make_unit(:model, 'D'))

      expect(chain(graph.shortest_path('A', 'D'))).to eq([%w[A Z], %w[Z D]])
    end

    it 'lists every via on the edge between two units, sorted' do
      register(make_unit(:model, 'Comment', { target: 'Post', via: :code_reference },
                         { target: 'Post', via: :belongs_to }, { target: 'Post', via: :code_reference }),
               make_unit(:model, 'Post'))

      expect(graph.shortest_path('Comment', 'Post')[:hops].first[:via]).to eq(%w[belongs_to code_reference])
    end

    it 'answers the same unit as zero hops' do
      register(make_unit(:model, 'Post', 'Post'))

      result = graph.shortest_path('Post', 'Post')

      expect(result).to include(found: true, hop_count: 0, hops: [], direction: 'forward')
    end

    it 'reads the same path from a graph restored from its JSON' do
      register(make_unit(:controller, 'A', 'B'), make_unit(:service, 'B', { target: 'C', via: :job_enqueue }),
               make_unit(:job, 'C'))
      restored = Woods::DependencyGraph.from_h(JSON.parse(JSON.generate(graph.to_h)))

      expect(restored.shortest_path('A', 'C')).to eq(graph.shortest_path('A', 'C'))
      expect(restored.shortest_path('A', 'C')[:hops].last[:via]).to eq(['job_enqueue'])
    end
  end

  describe 'determinism' do
    let(:units) do
      [make_unit(:controller, 'A', 'C', 'B'), make_unit(:service, 'B', 'D'), make_unit(:service, 'C', 'D'),
       make_unit(:model, 'D')]
    end

    it 'returns the same one of two equal-length paths whatever the registration order' do
      forward = register(*units, into: Woods::DependencyGraph.new)
      backward = register(*units.reverse, into: Woods::DependencyGraph.new)

      expect(chain(forward.shortest_path('A', 'D'))).to eq([%w[A B], %w[B D]])
      expect(backward.shortest_path('A', 'D')).to eq(forward.shortest_path('A', 'D'))
    end

    it 'orders an identifier registered under two types by type' do
      view = make_unit(:database_view, 'reports', 'D')
      factory = make_unit(:factory, 'reports', 'D')
      first = register(make_unit(:service, 'A', 'reports'), view, factory, make_unit(:model, 'D'),
                       into: Woods::DependencyGraph.new)
      second = register(make_unit(:model, 'D'), factory, view, make_unit(:service, 'A', 'reports'),
                        into: Woods::DependencyGraph.new)

      result = first.shortest_path('A', 'D')

      expect(result[:hops].first).to include(target: 'reports', target_type: 'database_view',
                                             target_types: %w[database_view factory])
      expect(second.shortest_path('A', 'D')).to eq(result)
    end
  end

  describe 'no path' do
    it 'says an exhausted search is exhaustive' do
      register(make_unit(:controller, 'A', 'B'), make_unit(:service, 'B'), make_unit(:model, 'D', 'A'))

      result = graph.shortest_path('A', 'D')

      expect(result).to include(found: false, exhaustive: true, hops: [], hop_count: nil, direction: nil)
      expect(result).not_to have_key(:partial_reason)
    end

    it 'does not loop on a cycle' do
      register(make_unit(:service, 'A', 'B'), make_unit(:service, 'B', 'C'), make_unit(:service, 'C', 'A'),
               make_unit(:model, 'D'))

      result = graph.shortest_path('A', 'D', max_depth: 20)

      expect(result).to include(found: false, exhaustive: true)
      expect(result[:searches].first).to include(visited_nodes: 3)
    end

    it 'says max_depth stopped the search when the target lies beyond it' do
      register(make_unit(:controller, 'A', 'B'), make_unit(:service, 'B', 'C'), make_unit(:service, 'C', 'D'),
               make_unit(:model, 'D'))

      result = graph.shortest_path('A', 'D', max_depth: 2)

      expect(result).to include(found: false, exhaustive: false, partial_reason: 'max_depth')
      expect(graph.shortest_path('A', 'D', max_depth: 3)).to include(found: true, hop_count: 3)
    end

    it 'stays exhaustive when the last level has nowhere further to go' do
      register(make_unit(:controller, 'A', 'B'), make_unit(:service, 'B', 'A'), make_unit(:model, 'D'))

      expect(graph.shortest_path('A', 'D', max_depth: 1)).to include(found: false, exhaustive: true)
    end

    it 'says the node budget stopped the search' do
      register(make_unit(:controller, 'A', 'B', 'C'), make_unit(:service, 'B', 'D'), make_unit(:service, 'C'),
               make_unit(:model, 'D'))

      result = graph.shortest_path('A', 'D', max_nodes: 2)

      expect(result).to include(found: false, exhaustive: false, partial_reason: 'node_budget')
      expect(result[:searches].first).to include(max_nodes: 2, visited_nodes: 2)
      expect(graph.shortest_path('A', 'D', max_nodes: 3)).to include(found: true)
    end

    it 'ignores edges to targets no unit is registered for' do
      register(make_unit(:service, 'A', 'ActiveRecord::Base'), make_unit(:model, 'D'))

      expect(graph.shortest_path('A', 'D', max_depth: 1)).to include(found: false, exhaustive: true)
    end
  end

  # The rule: a hop's evidence is the strongest of its vias, read by the type
  # of the unit the edge leaves; a path is as well supported as its weakest
  # hop, and one unclassified hop leaves the whole path unclassified.
  describe 'evidence' do
    it 'takes the strongest via of a hop' do
      register(make_unit(:model, 'Comment', { target: 'Post', via: :code_reference },
                         { target: 'Post', via: :belongs_to }), make_unit(:model, 'Post'))

      result = graph.shortest_path('Comment', 'Post')

      expect(result[:hops].first).to include(evidence: 'reflected')
      expect(result[:hops].first).not_to have_key(:evidence_mixed)
      expect(result).to include(evidence: 'reflected')
      expect(result).not_to have_key(:weakest_hop)
    end

    it 'gives the path its weakest hop and says which one' do
      register(make_unit(:route, 'GET /orders', { target: 'OrdersController', via: :route_dispatch }),
               make_unit(:controller, 'OrdersController', { target: 'orders/index', via: :job_enqueue }),
               make_unit(:view_template, 'orders/index', { target: 'Order', via: :view_render }),
               make_unit(:model, 'Order'))

      result = graph.shortest_path('GET /orders', 'Order')

      expect(result[:hops].map { |hop| hop[:evidence] }).to eq(%w[reflected static verified])
      expect(result).to include(evidence: 'static', weakest_hop: 2)
      expect(result).not_to have_key(:evidence_mixed)
    end

    it 'marks a hop whose pair two mechanisms produce, and the path it is weakest in' do
      register(make_unit(:controller, 'A', 'B'), make_unit(:service, 'B'))

      result = graph.shortest_path('A', 'B')

      expect(result[:hops].first).to include(evidence: 'static', evidence_mixed: true)
      expect(result).to include(evidence: 'static', weakest_hop: 1, evidence_mixed: true)
    end

    it 'is unknown for an unlabelled or unlisted hop, and then for the path' do
      register(make_unit(:model, 'A', { target: 'B', via: :belongs_to }),
               make_unit(:model, 'B', { target: 'C', via: :teleports_to }),
               make_unit(:model, 'C', { target: 'D', via: nil }), make_unit(:model, 'D'))

      result = graph.shortest_path('A', 'D')

      expect(result[:hops].map { |hop| hop[:evidence] }).to eq(%w[reflected unknown unknown])
      expect(result).to include(evidence: 'unknown', weakest_hop: 2)
    end

    it 'classifies a reverse hop by the unit the edge leaves, not the unit asked about' do
      register(make_unit(:concern, 'Auditable'), make_unit(:model, 'Order', { target: 'Auditable', via: :include }),
               make_unit(:concern, 'Trackable', { target: 'Auditable', via: :include }))

      from_model = graph.shortest_path('Auditable', 'Order', direction: 'either')
      from_concern = graph.shortest_path('Auditable', 'Trackable', direction: 'either')

      expect(from_model).to include(direction: 'reverse', evidence: 'verified')
      expect(from_model[:hops].first).to include(source_type: 'model', evidence: 'verified')
      expect(from_concern).to include(direction: 'reverse', evidence: 'static')
      expect(from_concern[:hops].first).to include(source_type: 'concern', evidence: 'static')
    end

    it 'carries no evidence for zero hops or no path' do
      register(make_unit(:model, 'A'), make_unit(:model, 'B'))

      expect(graph.shortest_path('A', 'A')).not_to have_key(:evidence)
      expect(graph.shortest_path('A', 'B')).not_to have_key(:evidence)
    end
  end

  describe 'direction' do
    before { register(make_unit(:model, 'Comment', { target: 'Post', via: :belongs_to }), make_unit(:model, 'Post')) }

    it 'does not follow edges backwards by default' do
      expect(graph.shortest_path('Post', 'Comment')).to include(found: false, exhaustive: true)
    end

    it 'finds the reverse path with either, and lists its hops as the edges run' do
      result = graph.shortest_path('Post', 'Comment', direction: 'either')

      expect(result).to include(found: true, direction: 'reverse', hop_count: 1)
      expect(result[:hops]).to eq([{ source: 'Comment', source_type: 'model', target: 'Post', target_type: 'model',
                                     via: ['belongs_to'], evidence: 'reflected' }])
      expect(result[:from]).to eq(identifier: 'Post', type: 'model')
    end

    it 'prefers the forward path with either' do
      expect(graph.shortest_path('Comment', 'Post', direction: 'either')).to include(direction: 'forward')
    end

    it 'reports both searches when neither direction has a path' do
      register(make_unit(:model, 'Island'))

      result = graph.shortest_path('Post', 'Island', direction: 'either')

      expect(result).to include(found: false, exhaustive: true)
      expect(result[:searches].map { |search| search[:direction] }).to eq(%w[forward reverse])
    end

    it 'is not exhaustive when a bound stopped either direction' do
      register(make_unit(:service, 'X', 'Y'), make_unit(:service, 'Y', 'Z'), make_unit(:service, 'Z'))

      result = graph.shortest_path('Z', 'X', direction: 'either', max_depth: 1)

      expect(result).to include(found: false, exhaustive: false, partial_reason: 'max_depth')
    end

    it 'refuses an unknown direction' do
      expect { graph.shortest_path('Post', 'Comment', direction: 'sideways') }.to raise_error(ArgumentError)
    end
  end

  describe 'documentation units' do
    before do
      register(make_unit(:service, 'A', 'docs/guide.md'), make_unit(:doc, 'docs/guide.md', 'D'),
               make_unit(:model, 'D'))
    end

    it 'does not route a path through a document' do
      expect(graph.shortest_path('A', 'D')).to include(found: false, exhaustive: true)
    end

    it 'still accepts a document as either endpoint' do
      expect(graph.shortest_path('A', 'docs/guide.md')).to include(found: true, hop_count: 1)
      expect(graph.shortest_path('docs/guide.md', 'D')).to include(found: true, hop_count: 1)
    end

    it 'keeps a path that does not need the document' do
      register(make_unit(:service, 'A', 'docs/guide.md', 'B'), make_unit(:service, 'B', 'D'))

      expect(chain(graph.shortest_path('A', 'D'))).to eq([%w[A B], %w[B D]])
    end

    context 'when the depth bound stops the search one hop short of a document' do
      before do
        register(make_unit(:service, 'A', 'B'), make_unit(:service, 'B', 'docs/deep.md', 'docs/other.md'),
                 make_unit(:doc, 'docs/deep.md'), make_unit(:doc, 'docs/other.md'), make_unit(:model, 'Z'))
      end

      it 'reports the bound when the document is the goal, and finds it one hop deeper' do
        stopped = graph.shortest_path('A', 'docs/deep.md', max_depth: 1)

        expect(stopped).to include(found: false, exhaustive: false, partial_reason: 'max_depth')
        expect(graph.shortest_path('A', 'docs/deep.md', max_depth: 2)).to include(found: true, hop_count: 2)
      end

      it 'stays exhaustive when the only units beyond the bound are documents that are not the goal' do
        expect(graph.shortest_path('A', 'Z', max_depth: 1)).to include(found: false, exhaustive: true)
      end
    end
  end

  describe 'schema units' do
    it 'ends a path at a table, which has no forward edges' do
      register(make_unit(:model, 'Post', { target: 'posts', via: :table }), make_unit(:database_table, 'posts'))

      expect(graph.shortest_path('Post', 'posts')).to include(found: true, hop_count: 1)
      expect(graph.shortest_path('posts', 'Post')).to include(found: false, exhaustive: true)
    end
  end

  describe 'an identifier registered under two types' do
    before do
      register(make_unit(:database_view, 'reports', 'Order'), make_unit(:factory, 'reports', 'Report'),
               make_unit(:model, 'Order'), make_unit(:model, 'Report'), make_unit(:service, 'A', 'reports'))
    end

    it 'starts from the type named' do
      expect(graph.shortest_path('reports', 'Report', from_type: 'factory')).to include(found: true, hop_count: 1)
      expect(graph.shortest_path('reports', 'Report', from_type: 'database_view')).to include(found: false)
    end

    it 'ends at the type named' do
      result = graph.shortest_path('A', 'reports', to_type: :factory)

      expect(result[:hops].last).to include(target: 'reports', target_type: 'factory')
      expect(result[:to]).to eq(identifier: 'reports', type: 'factory')
    end

    it 'takes the primary node when no type is named' do
      expect(graph.shortest_path('reports', 'Order')[:from]).to eq(identifier: 'reports', type: 'database_view')
    end

    it 'refuses a type the identifier is not registered under, and an unknown identifier' do
      expect { graph.shortest_path('reports', 'Order', from_type: 'model') }.to raise_error(ArgumentError, /reports/)
      expect { graph.shortest_path('A', 'Nowhere') }.to raise_error(ArgumentError, /Nowhere/)
    end
  end
end
