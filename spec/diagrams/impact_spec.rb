# frozen_string_literal: true

require 'spec_helper'
require 'woods/mcp/index_reader'
require 'woods/diagrams'
require 'woods/impact/report'
require 'woods/impact/renderers'

RSpec.describe Woods::Diagrams::Impact do
  include DiagramIndex

  before { Woods::Diagrams::Cache.clear }

  def build(**arguments)
    Woods::Diagrams.build(diagram_reader, kind: 'impact', index_dir: diagram_root, **arguments)
  end

  def report(depth)
    Woods::Impact::Report.focus(diagram_root, identities: [{ 'identifier' => 'User', 'type' => 'model' }],
                                              at: 'gen:1', depth: depth)
  end

  it 'draws the focus report at the reader\'s generation with its default depth of 2' do
    result = build(identifier: 'User')
    expect(result.text).to eq(Woods::Impact::Renderers.mermaid(report(2)).chomp)
    expect(result.details).to include('depth' => 2, 'affected' => 4, 'size' => 5, 'complete' => false)
  end

  it 'takes depth 0 to 10, the report\'s own range' do
    expect(build(identifier: 'User', depth: 0).text).to eq(Woods::Impact::Renderers.mermaid(report(0)).chomp)
    expect(build(identifier: 'User', depth: 10).details['depth']).to eq(10)
    expect { build(identifier: 'User', depth: 11) }
      .to raise_error(Woods::Diagrams::InvalidRequest, /impact depth must be 0 to 10/)
  end

  it 'refuses a report the renderer would truncate, instead of drawing a cut graph' do
    stub_const('Woods::Impact::Renderers::Mermaid::MAX_NODES', 3)
    result = build(identifier: 'User')
    expect([result.text, result.refusal])
      .to eq([nil, '5 units is over the impact diagram budget of 3 nodes and 120 edges'])
    expect(build(identifier: 'User', depth: 0)).to be_drawn
  end

  it 'needs the index root' do
    expect { Woods::Diagrams.build(diagram_reader, kind: 'impact', identifier: 'User') }
      .to raise_error(Woods::Diagrams::InvalidRequest, 'The impact kind needs the index root')
  end
end
