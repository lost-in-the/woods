# frozen_string_literal: true

require 'spec_helper'
require 'woods/mcp/tool_response_renderer'
require 'woods/mcp/renderers/markdown_renderer'

RSpec.describe Woods::MCP::Renderers::MarkdownRenderer do
  subject(:renderer) { described_class.new }

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
  end

  describe '#render_pagerank (#105)' do
    it 'labels the graph denominator explicitly' do
      out = renderer.render(:pagerank, { total_nodes: 6333, results: [] })
      expect(out).to include('Ranking 6333 nodes in the dependency graph.')
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
