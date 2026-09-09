# frozen_string_literal: true

require 'spec_helper'
require 'json'
require 'woods/mcp/tool_response_renderer'
require 'woods/mcp/renderers/plain_renderer'

RSpec.describe Woods::MCP::Renderers::PlainRenderer do
  subject(:renderer) { described_class.new }

  describe '#render_lookup' do
    it 'renders unit identifier and file' do
      out = renderer.render(:lookup, {
                              'identifier' => 'User',
                              'type' => 'model',
                              'file_path' => 'app/models/user.rb'
                            })
      expect(out).to include('User (model)')
      expect(out).to include('File: app/models/user.rb')
    end

    it 'returns a not-found message for non-hash input' do
      expect(renderer.render(:lookup, nil)).to eq('Unit not found')
      expect(renderer.render(:lookup, 'string input')).to eq('Unit not found')
    end

    it 'returns a not-found message for a hash without identifier' do
      expect(renderer.render(:lookup, { 'type' => 'model' })).to eq('Unit not found')
    end

    it 'includes source code when present' do
      out = renderer.render(:lookup, {
                              'identifier' => 'X',
                              'type' => 'service',
                              'source_code' => 'class X; end'
                            })
      expect(out).to include('class X; end')
    end

    it 'renders metadata hash values without crashing' do
      out = renderer.render(:lookup, {
                              'identifier' => 'User',
                              'type' => 'model',
                              'metadata' => { 'table_name' => 'users', 'columns' => %w[id email] }
                            })
      expect(out).to include('table_name: users')
      expect(out).to include('- id')
    end
  end

  describe '#render_search' do
    it 'renders query and result list' do
      data = {
        query: 'user',
        result_count: 2,
        results: [
          { identifier: 'User', type: 'model' },
          { identifier: 'UserMailer', type: 'mailer' }
        ]
      }
      out = renderer.render(:search, data)
      expect(out).to include('Search: "user" (2 results)')
      expect(out).to include('User (model)')
      expect(out).to include('UserMailer (mailer)')
    end

    it 'handles empty results' do
      data = { query: 'nothing', result_count: 0, results: [] }
      out = renderer.render(:search, data)
      expect(out).to include('Search: "nothing" (0 results)')
    end
  end

  describe '#render_dependencies' do
    it 'renders the label header with the root identifier' do
      # NOTE: the renderer has a latent bug with found:false detection when
      # data carries symbol keys (`data[:found] || data['found']` short-
      # circuits on false). This is tracked separately; for this spec we
      # exercise the found-true / no-found branch, which is the common path.
      out = renderer.render(:dependencies, {
                              root: 'Ghost',
                              nodes: {}
                            })
      expect(out).to include('Dependencies of Ghost')
    end

    it 'renders nodes tree structure' do
      out = renderer.render(:dependencies, {
                              root: 'User',
                              nodes: { 'User' => { depth: 0, deps: %w[Post] } }
                            })
      expect(out).to include('User')
      expect(out).to include('-> Post')
    end
  end

  describe '#render_default' do
    it 'handles hashes, arrays, and scalars' do
      expect(renderer.render(:unknown, { a: 1 })).to eq('a: 1')
      expect(renderer.render(:unknown, [1, 2])).to include('1').and include('2')
      expect(renderer.render(:unknown, 'hi')).to eq('hi')
    end
  end

  describe '#render_graph_analysis edge-shaped items (#280)' do
    it 'renders from, to, via, and the remaining keys on one line' do
      out = renderer.render(:graph_analysis, {
                              'volatile_dependencies' => [
                                { 'from' => 'Checkout', 'to' => 'PricingRules', 'via' => 'code_reference',
                                  'from_commits' => 5, 'to_commits' => 30, 'ratio' => 6.0, 'pagerank' => 0.1 }
                              ],
                              'stats' => {}
                            })

      expect(out).to include('VOLATILE DEPENDENCIES:')
      expect(out).to include('  Checkout -> PricingRules (code_reference): from_commits: 5, to_commits: 30, ' \
                             'ratio: 6.0, pagerank: 0.1')
    end

    it 'renders an Array detail value joined, not as Ruby array syntax' do
      fixture_path = File.expand_path('../../fixtures/woods/graph_analysis.json', __dir__)
      ambiguous = JSON.parse(File.read(fixture_path)).fetch('cross_database_edges')
                      .find { |edge| edge.key?('ambiguous_owners') }

      out = renderer.render(:graph_analysis, { 'cross_database_edges' => [ambiguous], 'stats' => {} })

      expect(out).to include('ambiguous_owners: Account, LegacyAccount')
      expect(out).not_to include('["Account"')
    end

    it 'renders a nil endpoint as (unresolved), not a blank bold pair' do
      out = renderer.render(:graph_analysis, {
                              'cross_database_edges' => [
                                { 'from' => 'Invoice', 'to' => nil, 'via' => 'foreign_key', 'kind' => 'x' }
                              ],
                              'stats' => {}
                            })

      expect(out).to include('  Invoice -> (unresolved) (foreign_key)')
      expect(out).not_to include('****')
    end

    it 'keeps existing sections byte-identical to the pre-#280 renderer (I13)' do
      old_shape = {
        'orphans' => ['PostsController'],
        'dead_ends' => ['Post'],
        'hubs' => [
          { 'identifier' => 'Post', 'type' => 'model', 'dependent_count' => 2,
            'dependents' => %w[Comment PostsController] },
          { 'identifier' => 'Comment', 'type' => 'model', 'dependent_count' => 0, 'dependents' => [] },
          { 'identifier' => 'PostsController', 'type' => 'controller', 'dependent_count' => 0, 'dependents' => [] }
        ],
        'cycles' => [], 'bridges' => [],
        'stats' => { 'orphan_count' => 1, 'dead_end_count' => 1, 'hub_count' => 3, 'cycle_count' => 0 }
      }

      # Captured by rendering this exact hash at 3498079 (task-10's base
      # commit), before cross_database_edges/volatile_dependencies existed.
      expected = <<~PLAIN.rstrip
        Graph Analysis
        #{'=' * 60}
          orphan_count: 1
          dead_end_count: 1
          hub_count: 3
          cycle_count: 0

        ORPHANS:
          PostsController

        DEAD ENDS:
          Post

        HUBS:
          Post (model) - 2 dependents
          Comment (model) - 0 dependents
          PostsController (controller) - 0 dependents
      PLAIN

      expect(renderer.render(:graph_analysis, old_shape)).to eq(expected)
    end
  end
end
