# frozen_string_literal: true

require 'spec_helper'
require 'json'
require 'woods/mcp/tool_response_renderer'

# The rule: no MCP tool text prints a Ruby `inspect` form. A nested Hash or
# Array reads as `(key: value)` and `[a, b]`, never `{"verb" => "GET"}` or
# `["a", "b"]`, which an agent would take for data.
RSpec.describe 'MCP text renderers on nested values' do
  let(:unit) do
    { 'identifier' => 'ThingsController', 'type' => 'controller',
      'metadata' => {
        'routes' => { 'show' => [{ 'verb' => 'GET', 'path' => '/things/:id' }], 'index' => { 'verb' => 'GET' } },
        'filters' => [{ 'name' => 'authorize', 'only' => %w[show edit], 'options' => { 'if' => 'admin?' } }],
        'matrix' => [%w[a b], { 'k' => 'v' }],
        'scalar' => 'plain'
      } }
  end

  # Ruby's Hash#inspect (`{"k" => "v"}`, or `{"k"=>"v"}` before 3.4) and
  # Array#inspect of strings (`["a", "b"]`).
  def expect_no_inspect(text)
    expect(text).not_to include('=>')
    expect(text).not_to match(/\{"|\["/)
  end

  %i[markdown plain claude].each do |format|
    describe "the #{format} format" do
      let(:renderer) { Woods::MCP::ToolResponseRenderer.for(format) }

      it 'prints nested lookup metadata without Ruby inspect output' do
        text = renderer.render(:lookup, unit)

        expect_no_inspect(text)
        expect(text).to include('verb: GET').and include('show, edit').and include('if: admin?')
      end

      it 'prints a nested result of a tool with no renderer of its own without Ruby inspect output' do
        text = renderer.render(:some_tool, { 'summary' => { 'nested' => { 'k' => 'v' }, 'list' => %w[a b] },
                                             'rows' => [{ 'name' => 'x', 'tags' => %w[t u] }] })

        expect_no_inspect(text)
      end

      it 'prints a search scope as a list, not an Array#inspect' do
        text = renderer.render(:search, { query: 'thing', result_count: 0, results: [],
                                          completeness: { status: 'complete', reason: 'all', has_more: false },
                                          applied_scope: { packages: %w[packs/a packs/b], source_paths: nil,
                                                           eligible_units: 2 } })

        expect_no_inspect(text)
        expect(text).to include('packages=[packs/a, packs/b]; source_paths=null')
      end

      it 'prints graph analysis stats and items holding nested values without Ruby inspect output' do
        text = renderer.render(:graph_analysis, { 'stats' => { 'by_type' => { 'model' => 3 } },
                                                  'orphans' => [%w[a b]] })

        expect_no_inspect(text)
        expect(text).to include('model: 3')
      end
    end
  end
end
