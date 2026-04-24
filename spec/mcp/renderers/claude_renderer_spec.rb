# frozen_string_literal: true

require 'spec_helper'
require 'woods/mcp/tool_response_renderer'
require 'woods/mcp/renderers/markdown_renderer'
require 'woods/mcp/renderers/claude_renderer'

RSpec.describe Woods::MCP::Renderers::ClaudeRenderer do
  subject(:renderer) { described_class.new }

  describe '#render_lookup' do
    it 'wraps the markdown body in a <lookup_result> XML tag' do
      out = renderer.render(:lookup, {
                              'identifier' => 'User',
                              'type' => 'model'
                            })
      expect(out).to start_with('<lookup_result ')
      expect(out).to include('identifier="User"')
      expect(out).to include('type="model"')
      expect(out).to end_with('</lookup_result>')
      expect(out).to include('## User (model)')
    end

    it 'returns "Unit not found" (no XML wrap) for non-hash input' do
      expect(renderer.render(:lookup, nil)).to eq('Unit not found')
      expect(renderer.render(:lookup, {})).to eq('Unit not found')
    end
  end

  describe '#render_search' do
    it 'wraps search results with the query attribute' do
      data = {
        query: 'auth flow',
        result_count: 1,
        results: [{ identifier: 'AuthService', type: 'service' }]
      }
      out = renderer.render(:search, data)
      expect(out).to start_with('<search_results ')
      expect(out).to include('query="auth flow"')
      expect(out).to end_with('</search_results>')
    end
  end

  describe '#render_dependencies' do
    it 'wraps in <dependencies> with root attribute' do
      out = renderer.render(:dependencies, {
                              'root' => 'User',
                              'nodes' => { 'User' => { 'depth' => 0, 'deps' => ['Post'] } }
                            })
      expect(out).to start_with('<dependencies ')
      expect(out).to include('root="User"')
      expect(out).to end_with('</dependencies>')
    end
  end

  describe '#render_structure' do
    it 'wraps structure in <structure>' do
      out = renderer.render(:structure, { manifest: { 'total_units' => 42 } })
      expect(out).to start_with('<structure>')
      expect(out).to end_with('</structure>')
    end
  end

  describe '#render_default' do
    it 'wraps unknown tool output in <result>' do
      out = renderer.render(:unknown, { foo: 'bar' })
      expect(out).to start_with('<result>')
      expect(out).to end_with('</result>')
    end
  end

  describe '#render_trace_flow' do
    it 'wraps the full markdown flow document in <trace_flow entry_point="...">' do
      flow = {
        entry_point: 'PostsController#create',
        steps: [
          { unit: 'PostsController#create', operations: [{ type: 'call', target: 'Post', method: 'create!', line: 7 }] }
        ]
      }
      out = renderer.render(:trace_flow, flow)
      expect(out).to start_with('<trace_flow entry_point="PostsController#create">')
      expect(out).to include('Post.create!')
      expect(out).to end_with('</trace_flow>')
    end
  end

  describe 'empty array / nil data edge cases' do
    it 'renders empty dependency trees without crashing' do
      out = renderer.render(:dependencies, { 'root' => 'X', 'nodes' => {} })
      expect(out).to include('<dependencies ')
    end

    it 'renders search with zero results' do
      out = renderer.render(:search, { query: 'nothing', result_count: 0, results: [] })
      expect(out).to include('<search_results ')
    end
  end
end
