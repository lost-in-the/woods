# frozen_string_literal: true

require 'spec_helper'
require 'woods'
require 'woods/mcp/server'

# The always-on `diagram` tool (woods#826): Mermaid for one unit from the
# published index, every kind with its own depth, refused over its budget.
RSpec.describe 'Index MCP diagram tool' do
  include DiagramIndex

  before { Woods::Diagrams::Cache.clear }

  let(:server) { Woods::MCP::Server.build(index_dir: diagram_root, warmup: false) }

  def call(**arguments)
    request = { jsonrpc: '2.0', id: 1, method: 'tools/call', params: { name: 'diagram', arguments: arguments } }
    JSON.parse(server.handle_json(JSON.generate(request))).fetch('result')
  end

  def code(result)
    result.dig('_meta', 'error_code')
  end

  it 'is always registered, in the sorted tool order, and documents depth per kind' do
    expect(server.tools).to have_key('diagram')
    expect(server.tools.keys).to eq(server.tools.keys.sort)
    depth = server.tools['diagram'].input_schema_value.to_h.dig(:properties, :depth, :description)
    expect(depth).to include('neighbourhood: graph hops from the unit, 1 to 3, default 1',
                             'schema: association hops from the model\'s table, 1 to 3, default 1',
                             'lifecycle: 0 is the model event\'s own callback chain', '0 to 2, default 0',
                             'impact: reverse dependency hops of the change impact report, 0 to 10, default 2')
  end

  it 'answers each kind\'s Mermaid with its depth and generation, the default when depth is omitted' do
    { 'neighbourhood' => [1, 'flowchart LR'], 'schema' => [1, 'erDiagram'], 'lifecycle' => [0, 'sequenceDiagram'],
      'impact' => [2, 'flowchart LR'] }.each do |kind, (depth, start)|
      result = call(kind: kind, identifier: 'Post')
      expect(result['isError']).to be(false), kind
      expect(result.dig('content', 0, 'text')).to start_with(start)
      expect(result.dig('structuredContent', 'data')).to include('kind' => kind, 'identifier' => 'Post',
                                                                 'type' => 'model', 'depth' => depth,
                                                                 'generation' => 1)
    end
  end

  it 'takes each kind\'s maximum depth and refuses one past it as invalid_params' do
    { 'neighbourhood' => 3, 'schema' => 3, 'lifecycle' => 2, 'impact' => 10 }.each do |kind, max|
      expect(call(kind: kind, identifier: 'Post', depth: max).dig('structuredContent', 'data', 'depth')).to eq(max)
      next if max == 10

      refused = call(kind: kind, identifier: 'Post', depth: max + 1)
      expect([refused['isError'], code(refused)]).to eq([true, 'invalid_params']), kind
      expect(refused.dig('content', 0, 'text')).to start_with("#{kind} depth must be")
    end
    expect(code(call(kind: 'impact', identifier: 'Post', depth: 11))).to eq('invalid_arguments')
    expect(code(call(kind: 'neighbourhood', identifier: 'Post', depth: 0))).to eq('invalid_params')
  end

  it 'refuses a diagram over its budget with the reason and its size, so the agent can retry smaller' do
    stub_const('Woods::Diagrams::Lifecycle::SEQUENCE_BUDGET', 10)
    result = call(kind: 'lifecycle', identifier: 'Post', depth: 2)
    expect([result['isError'], code(result)]).to eq([true, 'over_budget'])
    expect(result.dig('content', 0, 'text'))
      .to eq('13 participants and messages is over the sequence budget of 10 (depth 2). No diagram is drawn above ' \
             'the budget; retry with a smaller depth or narrower filters.')
    expect(result['_meta']).to include('depth' => 2, 'budget' => 10, 'size' => 13)
    expect(call(kind: 'lifecycle', identifier: 'Post', depth: 0)['isError']).to be(false)
  end

  it 'answers an unknown unit as not_found and a kind the unit cannot have as invalid_params' do
    expect(code(call(kind: 'schema', identifier: 'Nope'))).to eq('not_found')
    expect(code(call(kind: 'lifecycle', identifier: 'NotifyJob'))).to eq('invalid_params')
    expect(code(call(kind: 'schema', identifier: 'Post', direction: 'both'))).to eq('invalid_params')
    expect(code(call(kind: 'neighbourhood', identifier: 'Post', direction: 'up'))).to eq('invalid_arguments')
  end
end
