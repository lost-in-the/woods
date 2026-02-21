# frozen_string_literal: true

require 'spec_helper'
require 'codebase_index/mcp/tool_response_renderer'
require 'codebase_index/mcp/renderers/markdown_renderer'
require 'codebase_index/mcp/renderers/claude_renderer'
require 'codebase_index/mcp/renderers/plain_renderer'
require 'codebase_index/mcp/renderers/json_renderer'

RSpec.describe CodebaseIndex::MCP::ToolResponseRenderer do
  describe '.for' do
    it 'returns a MarkdownRenderer for :markdown' do
      expect(described_class.for(:markdown)).to be_a(CodebaseIndex::MCP::Renderers::MarkdownRenderer)
    end

    it 'returns a ClaudeRenderer for :claude' do
      expect(described_class.for(:claude)).to be_a(CodebaseIndex::MCP::Renderers::ClaudeRenderer)
    end

    it 'returns a PlainRenderer for :plain' do
      expect(described_class.for(:plain)).to be_a(CodebaseIndex::MCP::Renderers::PlainRenderer)
    end

    it 'returns a JsonRenderer for :json' do
      expect(described_class.for(:json)).to be_a(CodebaseIndex::MCP::Renderers::JsonRenderer)
    end

    it 'raises ArgumentError for unknown format' do
      expect { described_class.for(:xml) }.to raise_error(ArgumentError, /Unknown format/)
    end
  end

  describe '#render' do
    let(:renderer) { described_class.for(:markdown) }

    it 'dispatches to render_<tool_name> when method exists' do
      data = unit_fixture
      result = renderer.render(:lookup, data)
      expect(result).to include('## Post (model)')
    end

    it 'falls back to render_default for unknown tool names' do
      result = renderer.render(:unknown_tool, { 'key' => 'value' })
      expect(result).to include('key')
    end
  end

  # ── JSON Renderer ──────────────────────────────────────────────────

  describe CodebaseIndex::MCP::Renderers::JsonRenderer do
    let(:renderer) { described_class.new }

    it 'returns pretty-printed JSON for any data' do
      data = { 'key' => 'value', 'count' => 42 }
      result = renderer.render(:lookup, data)
      expect(JSON.parse(result)).to eq(data)
    end

    it 'handles arrays' do
      data = [1, 2, 3]
      result = renderer.render_default(data)
      expect(JSON.parse(result)).to eq(data)
    end
  end

  # ── Markdown Renderer ──────────────────────────────────────────────

  describe CodebaseIndex::MCP::Renderers::MarkdownRenderer do
    let(:renderer) { described_class.new }

    describe '#render_lookup' do
      it 'renders unit with heading, file path, and source' do
        result = renderer.render(:lookup, unit_fixture)
        expect(result).to include('## Post (model)')
        expect(result).to include('**File:** `app/models/post.rb`')
        expect(result).to include('```ruby')
        expect(result).to include('has_many :comments')
        expect(result).to include('```')
      end

      it 'renders dependents section' do
        result = renderer.render(:lookup, unit_fixture)
        expect(result).to include('### Dependents')
        expect(result).to include('- Comment')
        expect(result).to include('- PostsController')
      end

      it 'renders metadata section' do
        result = renderer.render(:lookup, unit_fixture)
        expect(result).to include('### Metadata')
        expect(result).to include('**table_name:** posts')
      end

      it 'returns not found for nil data' do
        expect(renderer.render(:lookup, nil)).to eq('Unit not found')
      end

      it 'returns not found for empty hash' do
        expect(renderer.render(:lookup, {})).to eq('Unit not found')
      end

      it 'omits source section when source_code is absent' do
        data = unit_fixture.except('source_code')
        result = renderer.render(:lookup, data)
        expect(result).not_to include('### Source')
        expect(result).not_to include('```ruby')
      end
    end

    describe '#render_search' do
      it 'renders search heading and result count' do
        result = renderer.render(:search, search_fixture)
        expect(result).to include('## Search: "Post"')
        expect(result).to include('2 results found.')
      end

      it 'renders each result as a bullet' do
        result = renderer.render(:search, search_fixture)
        expect(result).to include('- **Post** (model)')
        expect(result).to include('- **PostsController** (controller)')
      end
    end

    describe '#render_dependencies' do
      it 'renders dependency tree' do
        result = renderer.render(:dependencies, traversal_fixture)
        expect(result).to include('## Dependencies of Comment')
        expect(result).to include('**Comment**')
      end

      it 'renders not found message' do
        data = { 'root' => 'Missing', 'nodes' => {}, 'found' => false,
                 'message' => "Identifier 'Missing' not found in the index." }
        result = renderer.render(:dependencies, data)
        expect(result).to include('not found in the index')
      end
    end

    describe '#render_structure' do
      it 'renders manifest info and counts table' do
        result = renderer.render(:structure, structure_fixture)
        expect(result).to include('## Codebase Structure')
        expect(result).to include('**Rails version:** 8.1.2')
        expect(result).to include('| Type | Count |')
        expect(result).to include('| models | 2 |')
      end

      it 'includes summary when present' do
        data = structure_fixture.merge('summary' => 'Project overview here.')
        result = renderer.render(:structure, data)
        expect(result).to include('### Summary')
        expect(result).to include('Project overview here.')
      end
    end

    describe '#render_graph_analysis' do
      it 'renders stats and sections' do
        result = renderer.render(:graph_analysis, graph_analysis_fixture)
        expect(result).to include('## Graph Analysis')
        expect(result).to include('**orphan_count:** 1')
        expect(result).to include('### Orphans')
        expect(result).to include('- PostsController')
      end

      it 'renders hub entries with dependent counts' do
        result = renderer.render(:graph_analysis, graph_analysis_fixture)
        expect(result).to include('### Hubs')
        expect(result).to include('**Post** (model)')
      end

      it 'shows truncation note when present' do
        data = graph_analysis_fixture.merge('hubs_total' => 10, 'hubs_truncated' => true)
        result = renderer.render(:graph_analysis, data)
        expect(result).to include('Showing 3 of 10 (truncated)')
      end
    end

    describe '#render_pagerank' do
      it 'renders a markdown table with rank, identifier, type, and score' do
        result = renderer.render(:pagerank, pagerank_fixture)
        expect(result).to include('## PageRank Scores')
        expect(result).to include('| Rank | Identifier | Type | Score |')
        expect(result).to include('| 1 | Post | model |')
      end
    end

    describe '#render_framework' do
      it 'renders framework search results' do
        data = { 'keyword' => 'ActiveRecord', 'result_count' => 1,
                 'results' => [{ 'identifier' => 'ActiveRecord::Base', 'type' => 'rails_source',
                                 'file_path' => 'activerecord/lib/active_record/base.rb' }] }
        result = renderer.render(:framework, data)
        expect(result).to include('## Framework: "ActiveRecord"')
        expect(result).to include('**ActiveRecord::Base** (rails_source)')
        expect(result).to include('`activerecord/lib/active_record/base.rb`')
      end
    end

    describe '#render_recent_changes' do
      it 'renders a markdown table of recent changes' do
        data = { 'result_count' => 1,
                 'results' => [{ 'identifier' => 'Post', 'type' => 'model',
                                 'last_modified' => '2026-01-15', 'author' => 'dev@example.com' }] }
        result = renderer.render(:recent_changes, data)
        expect(result).to include('## Recent Changes')
        expect(result).to include('| Post | model | 2026-01-15 | dev@example.com |')
      end
    end

    describe '#render_default' do
      it 'renders hashes as key-value pairs' do
        result = renderer.render_default({ 'status' => 'ok', 'count' => 5 })
        expect(result).to include('**status:** ok')
        expect(result).to include('**count:** 5')
      end

      it 'renders arrays of hashes as tables' do
        data = [{ 'name' => 'Alice', 'role' => 'admin' }, { 'name' => 'Bob', 'role' => 'user' }]
        result = renderer.render_default(data)
        expect(result).to include('| name | role |')
        expect(result).to include('| Alice | admin |')
      end

      it 'renders simple arrays as bullet lists' do
        result = renderer.render_default(%w[one two three])
        expect(result).to include('- one')
        expect(result).to include('- two')
      end

      it 'renders scalars as strings' do
        expect(renderer.render_default(42)).to eq('42')
      end
    end
  end

  # ── Claude Renderer ────────────────────────────────────────────────

  describe CodebaseIndex::MCP::Renderers::ClaudeRenderer do
    let(:renderer) { described_class.new }

    it 'wraps lookup in XML tags with attributes' do
      result = renderer.render(:lookup, unit_fixture)
      expect(result).to start_with('<lookup_result identifier="Post" type="model">')
      expect(result).to end_with('</lookup_result>')
      expect(result).to include('## Post (model)')
    end

    it 'wraps search in XML tags' do
      result = renderer.render(:search, search_fixture)
      expect(result).to start_with('<search_results query="Post">')
      expect(result).to end_with('</search_results>')
    end

    it 'wraps dependencies in XML tags' do
      result = renderer.render(:dependencies, traversal_fixture)
      expect(result).to start_with('<dependencies root="Comment">')
      expect(result).to end_with('</dependencies>')
    end

    it 'wraps dependents in XML tags' do
      data = traversal_fixture.merge('root' => 'Post')
      result = renderer.render(:dependents, data)
      expect(result).to start_with('<dependents root="Post">')
      expect(result).to end_with('</dependents>')
    end

    it 'wraps structure in XML tags' do
      result = renderer.render(:structure, structure_fixture)
      expect(result).to start_with('<structure>')
      expect(result).to end_with('</structure>')
    end

    it 'wraps graph_analysis in XML tags' do
      result = renderer.render(:graph_analysis, graph_analysis_fixture)
      expect(result).to start_with('<graph_analysis>')
      expect(result).to end_with('</graph_analysis>')
    end

    it 'wraps pagerank in XML tags' do
      result = renderer.render(:pagerank, pagerank_fixture)
      expect(result).to start_with('<pagerank>')
      expect(result).to end_with('</pagerank>')
    end

    it 'wraps framework in XML tags with keyword' do
      data = { 'keyword' => 'AR', 'result_count' => 0, 'results' => [] }
      result = renderer.render(:framework, data)
      expect(result).to start_with('<framework_results keyword="AR">')
    end

    it 'wraps recent_changes in XML tags' do
      data = { 'result_count' => 0, 'results' => [] }
      result = renderer.render(:recent_changes, data)
      expect(result).to start_with('<recent_changes>')
    end

    it 'wraps default output in result XML tags' do
      result = renderer.render_default({ 'key' => 'value' })
      expect(result).to start_with('<result>')
      expect(result).to end_with('</result>')
    end
  end

  # ── Plain Renderer ─────────────────────────────────────────────────

  describe CodebaseIndex::MCP::Renderers::PlainRenderer do
    let(:renderer) { described_class.new }

    it 'renders lookup with text dividers' do
      result = renderer.render(:lookup, unit_fixture)
      expect(result).to include('Post (model)')
      expect(result).to include('=' * 60)
      expect(result).to include('File: app/models/post.rb')
      expect(result).to include('has_many :comments')
    end

    it 'renders search with text dividers' do
      result = renderer.render(:search, search_fixture)
      expect(result).to include('Search: "Post" (2 results)')
      expect(result).to include('Post (model)')
    end

    it 'renders structure with key-value pairs' do
      result = renderer.render(:structure, structure_fixture)
      expect(result).to include('Codebase Structure')
      expect(result).to include('rails_version: 8.1.2')
      expect(result).to include('models: 2')
    end

    it 'renders pagerank as numbered list' do
      result = renderer.render(:pagerank, pagerank_fixture)
      expect(result).to include('1. Post (model) - 0.5')
    end

    it 'renders default hash as key-value pairs' do
      result = renderer.render_default({ 'status' => 'ok' })
      expect(result).to include('status: ok')
    end
  end

  # ── Shared fixtures ────────────────────────────────────────────────

  def unit_fixture
    {
      'type' => 'model',
      'identifier' => 'Post',
      'file_path' => 'app/models/post.rb',
      'namespace' => nil,
      'source_code' => "class Post < ApplicationRecord\n  has_many :comments\nend\n",
      'metadata' => {
        'table_name' => 'posts',
        'associations' => [{ 'type' => 'has_many', 'name' => 'comments' }]
      },
      'dependencies' => [],
      'dependents' => %w[Comment PostsController]
    }
  end

  def search_fixture
    {
      'query' => 'Post',
      'result_count' => 2,
      'results' => [
        { 'identifier' => 'Post', 'type' => 'model' },
        { 'identifier' => 'PostsController', 'type' => 'controller' }
      ]
    }
  end

  def traversal_fixture
    {
      'root' => 'Comment',
      'found' => true,
      'nodes' => {
        'Comment' => { 'depth' => 0, 'deps' => ['Post'] },
        'Post' => { 'depth' => 1, 'deps' => [] }
      }
    }
  end

  def structure_fixture
    {
      'manifest' => {
        'rails_version' => '8.1.2',
        'ruby_version' => '4.0.1',
        'git_branch' => 'main',
        'git_sha' => 'abc1234',
        'extracted_at' => '2026-01-15T12:00:00Z',
        'total_units' => 5,
        'counts' => { 'models' => 2, 'controllers' => 1 }
      }
    }
  end

  def graph_analysis_fixture
    {
      'orphans' => ['PostsController'],
      'dead_ends' => ['Post'],
      'hubs' => [
        { 'identifier' => 'Post', 'type' => 'model', 'dependent_count' => 2,
          'dependents' => %w[Comment PostsController] },
        { 'identifier' => 'Comment', 'type' => 'model', 'dependent_count' => 0, 'dependents' => [] },
        { 'identifier' => 'PostsController', 'type' => 'controller', 'dependent_count' => 0, 'dependents' => [] }
      ],
      'cycles' => [],
      'bridges' => [],
      'stats' => { 'orphan_count' => 1, 'dead_end_count' => 1, 'hub_count' => 3, 'cycle_count' => 0 }
    }
  end

  def pagerank_fixture
    {
      'total_nodes' => 3,
      'results' => [
        { 'identifier' => 'Post', 'type' => 'model', 'score' => 0.5 },
        { 'identifier' => 'Comment', 'type' => 'model', 'score' => 0.3 },
        { 'identifier' => 'PostsController', 'type' => 'controller', 'score' => 0.2 }
      ]
    }
  end
end
