# frozen_string_literal: true

require 'spec_helper'
require 'json'
require 'woods/mcp/tool_response_renderer'
require 'woods/mcp/renderers/markdown_renderer'

RSpec.describe Woods::MCP::Renderers::MarkdownRenderer do
  subject(:renderer) { described_class.new }

  describe '#render_lookup_member' do
    # An answer with candidates selects no definition, so the definitions
    # they override are not overridden by one "above".
    it 'says the candidates override a farther definition in an answer without a member' do
      data = { 'identifier' => 'ReportsController#render_pdf',
               'member_of' => { 'identifier' => 'ReportsController', 'type' => 'controller',
                                'file_path' => 'app/controllers/reports_controller.rb' },
               'statement' => 'ReportsController#render_pdf: Woods cannot tell which one Ruby calls.',
               'candidates' => [{ 'member' => { 'line' => 4, 'end_line' => 6, 'file_line' => 2, 'file_end_line' => 4 },
                                  'defined_in' => { 'identifier' => 'Exportable', 'file_path' => 'app/x.rb' } }],
               'other_definitions' => [{ 'line' => 9, 'end_line' => 11, 'unit' => 'ApplicationController' }] }

      text = renderer.render(:lookup_member, data)

      expect(text).to include('- Also defined in the published source of ApplicationController, lines 9-11; ' \
                              'each of the candidates overrides it.')
      expect(text).not_to include('the definition above')
    end
  end

  describe '#render_lookup' do
    it 'renders a markdown heading and file path' do
      out = renderer.render(:lookup, {
                              'identifier' => 'User',
                              'type' => 'model',
                              'file_path' => 'app/models/user.rb'
                            })
      expect(out).to include('## User (model)')
      expect(out).to include('**File:** `app/models/user.rb`')
    end

    it 'wraps source_code in a fenced code block' do
      out = renderer.render(:lookup, {
                              'identifier' => 'X',
                              'type' => 'service',
                              'source_code' => "class X\n  def call; end\nend"
                            })
      expect(out).to include('```ruby')
      expect(out).to include('class X')
      expect(out).to include('```')
    end

    it 'marks a route no action answers and leaves the others as they are' do
      out = renderer.render(:lookup, {
                              'identifier' => 'ThingsController', 'type' => 'controller',
                              'metadata' => { 'routes' => { 'show' => 'GET /things/:id',
                                                            'destroy' => 'DELETE /things/:id' },
                                              'routes_without_action' => ['destroy'] }
                            })
      expect(out).to include('**routes:** show=GET /things/:id, destroy (no action)=DELETE /things/:id')
      expect(out).to include("**routes_without_action:**\n  - destroy")
    end

    it 'prints no metadata key that has nothing to say' do
      out = renderer.render(:lookup, {
                              'identifier' => 'ThingsController', 'type' => 'controller',
                              'metadata' => { 'routes' => { 'show' => 'GET /things/:id' },
                                              'routes_without_action' => [], 'empty_hash' => {} }
                            })
      expect(out).not_to include('**routes_without_action:**')
      expect(out).not_to include('**empty_hash:**')
      expect(out).to include('show=GET /things/:id')
    end

    it 'marks no route of a unit that carries no routes_without_action' do
      out = renderer.render(:lookup, {
                              'identifier' => 'ThingsController', 'type' => 'controller',
                              'metadata' => { 'routes' => { 'destroy' => 'DELETE /things/:id' } }
                            })
      expect(out).to include('**routes:** destroy=DELETE /things/:id')
    end

    it 'returns "Unit not found" for non-hash input' do
      expect(renderer.render(:lookup, nil)).to eq('Unit not found')
      expect(renderer.render(:lookup, {})).to eq('Unit not found')
    end

    it 'lists dependencies and dependents' do
      out = renderer.render(:lookup, {
                              'identifier' => 'User',
                              'type' => 'model',
                              'dependencies' => %w[Post Comment],
                              'dependents' => %w[UserController]
                            })
      expect(out).to include('### Dependencies')
      expect(out).to include('- Post')
      expect(out).to include('- Comment')
      expect(out).to include('### Dependents')
      expect(out).to include('- UserController')
    end

    context 'when metadata entries carry file coordinates beside published lines' do
      let(:metadata) do
        {
          'methods' => [
            { 'name' => 'activate', 'line' => 276, 'end_line' => 280, 'file_line' => 271, 'file_end_line' => 275 },
            { 'name' => 'archived?', 'line' => 753, 'end_line' => 753, 'file_line' => 4, 'file_end_line' => 4,
              'file_unit' => 'Archivable' },
            { 'name' => 'from_second_contributor', 'line' => 2, 'end_line' => 2,
              'file_line' => nil, 'file_end_line' => nil }
          ],
          'callbacks' => [
            { 'type' => 'before_save', 'method' => 'normalize',
              'declaration' => { 'line' => 18, 'end_line' => 18, 'file_line' => 13, 'file_end_line' => 13 } }
          ]
        }
      end

      let(:out) { renderer.render(:lookup, { 'identifier' => 'Account', 'type' => 'model', 'metadata' => metadata }) }

      it 'leads with the file range and labels the annotated range as published source' do
        expect(out).to include('  - file lines: 271-275, published source lines: 276-280, name: activate')
      end

      it 'names the concern that owns a line inside an inlined block' do
        expect(out).to include('  - file lines: 4 in Archivable, published source lines: 753, name: archived?')
      end

      # Null also covers real code Woods cannot map (a secondary library
      # contributor), so the label must not claim the line is Woods' own.
      it 'labels a line with no file line as not mapped without guessing its origin' do
        expect(out).to include('  - file line: not mapped, published source lines: 2, name: from_second_contributor')
        expect(out).not_to include('annotation')
      end

      it 'labels a nested declaration site instead of printing a raw hash' do
        expect(out).to include('declaration: (file lines: 13, published source lines: 18)')
        expect(out).not_to include('=>')
      end

      it 'never prints a bare line key for an entry that has file coordinates' do
        expect(out).not_to match(/(?:- |, |\()line: /)
      end
    end

    it 'leaves entries without file coordinates as plain key-value pairs' do
      out = renderer.render(:lookup, { 'identifier' => 'X', 'type' => 'service',
                                       'metadata' => { 'routes' => [{ 'verb' => 'GET', 'line' => 3 }] } })
      expect(out).to include('  - verb: GET, line: 3')
    end
  end

  describe '#render_trace_flow' do
    it 'renders each step with a full operations table (not the truncated hash fallback)' do
      flow = {
        entry_point: 'PostsController#create',
        route: { verb: 'POST', path: '/posts' },
        max_depth: 3,
        steps: [
          {
            unit: 'PostsController#create',
            type: 'controller',
            file_path: 'app/controllers/posts_controller.rb',
            operations: [
              { type: 'call', target: 'Post', method: 'create!', line: 7 },
              { type: 'async', target: 'NotifyJob', method: 'perform_later', line: 8 },
              { type: 'response', status_code: 201, render_method: 'render', line: 9 }
            ]
          }
        ]
      }

      out = renderer.render(:trace_flow, flow)

      expect(out).to include('POST /posts → PostsController#create')
      expect(out).to include('### 1. PostsController#create')
      expect(out).to include('app/controllers/posts_controller.rb')
      expect(out).to include('| # | Operation | Target | Line |')
      expect(out).to include('Post.create!')
      expect(out).to include('NotifyJob.perform_later')
      expect(out).to include('201 (via render)')
    end

    it 'accepts string-keyed data (JSON round-trip)' do
      flow = {
        'entry_point' => 'X#y',
        'steps' => [
          { 'unit' => 'X#y', 'operations' => [{ 'type' => 'call', 'target' => 'Y', 'method' => 'z', 'line' => 1 }] }
        ]
      }
      out = renderer.render(:trace_flow, flow)
      expect(out).to include('X#y')
      expect(out).to include('Y.z')
    end
  end

  describe '#render_structure (#105)' do
    it 'labels the total-units line as "Total units indexed" (units_indexed denominator)' do
      out = renderer.render(:structure, { manifest: { 'total_units' => 6335, 'counts' => {} } })
      expect(out).to include('**Total units indexed:** 6335')
    end

    it 'appends the denominators glossary explaining why counts differ across tools' do
      out = renderer.render(:structure, { manifest: { 'total_units' => 100, 'counts' => { 'model' => 5 } } })
      expect(out).to include('### Denominators')
      expect(out).to include('units_indexed')
      expect(out).to include('graph_nodes')
      expect(out).to include('searchable_entries')
    end

    it 'reports supported template engines (#86)' do
      out = renderer.render(:structure, {
                              manifest: { 'total_units' => 10, 'counts' => {} },
                              template_engines: [:erb]
                            })
      expect(out).to include('**Supported template engines:** erb')
    end
  end

  describe '#render_pagerank (#105)' do
    it 'labels the graph denominator explicitly' do
      out = renderer.render(:pagerank, { total_nodes: 6333, results: [] })
      expect(out).to include('Ranking 6333 nodes in the dependency graph.')
    end
  end

  describe '#render_graph_analysis edge-shaped items (#280)' do
    it 'renders from, to, via, and the remaining keys on one line' do
      out = renderer.render(:graph_analysis, {
                              'cross_database_edges' => [
                                { 'from' => 'Invoice', 'to' => 'Account', 'via' => 'has_many',
                                  'from_db' => 'billing', 'to_db' => 'primary', 'through' => 'subscriptions',
                                  'disable_joins' => false, 'kind' => 'join_through_across_databases' }
                              ],
                              'stats' => { 'cross_database_edge_count' => 1 }
                            })

      expect(out).to include('### Cross database edges')
      expect(out).to include('- **Invoice** -> **Account** (has_many): from_db: billing, to_db: primary, ' \
                             'through: subscriptions, disable_joins: false, kind: join_through_across_databases')
    end

    it 'renders an Array detail value joined, not as Ruby array syntax' do
      fixture_path = File.expand_path('../../fixtures/woods/graph_analysis.json', __dir__)
      ambiguous = JSON.parse(File.read(fixture_path)).fetch('cross_database_edges')
                      .find { |edge| edge.key?('ambiguous_owners') }

      out = renderer.render(:graph_analysis, { 'cross_database_edges' => [ambiguous], 'stats' => {} })

      expect(out).to include('ambiguous_owners: Account, LegacyAccount')
      expect(out).not_to include('["Account"')
    end

    it 'renders a nil endpoint as (unresolved), not an empty bold pair' do
      out = renderer.render(:graph_analysis, {
                              'cross_database_edges' => [
                                { 'from' => 'Invoice', 'to' => nil, 'via' => 'foreign_key', 'kind' => 'x' }
                              ],
                              'stats' => {}
                            })

      expect(out).to include('- **Invoice** -> (unresolved) (foreign_key)')
      expect(out).not_to include('****')
    end

    it 'renders an unresolvable_routes entry as route, dispatch target and reason' do
      out = renderer.render(:graph_analysis, {
                              'unresolvable_routes' => [
                                { 'route' => 'DELETE /posts/:id', 'controller' => 'PostsController',
                                  'action' => 'destroy', 'reason' => 'missing_action' }
                              ],
                              'stats' => { 'unresolvable_route_count' => 1 }
                            })

      expect(out).to include('### Unresolvable routes')
      expect(out).to include('- **DELETE /posts/:id** -> PostsController#destroy (missing_action)')
      expect(out).not_to include('dependents')
    end

    it 'renders an undeclared_package_edges entry generically, with no dedicated branch' do
      out = renderer.render(:graph_analysis, {
                              'undeclared_package_edges' => [
                                { 'from' => 'PostsController', 'from_type' => 'controller', 'to' => 'BillingService',
                                  'to_type' => 'service', 'via' => 'code_reference', 'from_package' => 'checkout',
                                  'to_package' => 'billing' }
                              ],
                              'stats' => { 'undeclared_package_edge_count' => 1 }
                            })

      expect(out).to include('### Undeclared package edges')
      expect(out).to include('- **PostsController** -> **BillingService** (code_reference): from_type: controller, ' \
                             'to_type: service, from_package: checkout, to_package: billing')
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
      expected = <<~MARKDOWN.rstrip
        ## Graph Analysis

        - **orphan_count:** 1
        - **dead_end_count:** 1
        - **hub_count:** 3
        - **cycle_count:** 0

        ### Orphans

        - PostsController

        ### Dead ends

        - Post

        ### Hubs

        - **Post** (model) — 2 dependents
        - **Comment** (model) — 0 dependents
        - **PostsController** (controller) — 0 dependents
      MARKDOWN

      expect(renderer.render(:graph_analysis, old_shape)).to eq(expected)
    end
  end

  describe '#render_default' do
    it 'renders a hash as markdown-style bold keys' do
      out = renderer.render(:totally_unknown, { a: 1, b: 2 })
      expect(out).to include('**a:**').and include('**b:**')
    end

    it 'handles strings without crashing' do
      expect(renderer.render(:totally_unknown, 'hello')).to include('hello')
    end
  end
end
