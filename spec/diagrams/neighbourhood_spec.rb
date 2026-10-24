# frozen_string_literal: true

require 'spec_helper'
require 'woods/mcp/index_reader'
require 'woods/diagrams'

RSpec.describe Woods::Diagrams::Neighbourhood do
  include DiagramIndex

  before { Woods::Diagrams::Cache.clear }

  def build(**arguments)
    Woods::Diagrams.build(diagram_reader, kind: 'neighbourhood', **arguments)
  end

  def node(identifier, type)
    "n_#{Digest::SHA256.hexdigest([type, identifier].to_json)[0, 16]}[#{"#{identifier} (#{type})".to_json}]"
  end

  def id(identifier, type)
    node(identifier, type)[/\An_\h+/]
  end

  it 'draws the typed edges around the unit at depth 1 by default, each unit declared once, the unit classed focus' do
    result = build(identifier: 'AuditJob')
    expect(result.text).to eq(<<~MERMAID.chomp)
      flowchart LR
        #{node('AuditJob', 'job')}
        #{node('User', 'model')}
        #{node('NotifyJob', 'job')}
        #{id('AuditJob', 'job')} -->|code_reference| #{id('User', 'model')}
        #{id('NotifyJob', 'job')} -->|job_enqueue| #{id('AuditJob', 'job')}
        classDef focus stroke-width:3px
        class #{id('AuditJob', 'job')} focus
    MERMAID
    expect(result.details).to include('depth' => 1, 'direction' => 'both', 'size' => 3, 'edges' => 2)
  end

  it 'follows each hop breadth-first, every edge once, up to depth 3' do
    depths = (1..3).map { |depth| build(identifier: 'AuditJob', depth: depth).details['edges'] }
    expect(depths).to eq([2, 10, 13])
    expect { build(identifier: 'AuditJob', depth: 4) }
      .to raise_error(Woods::Diagrams::InvalidRequest, /neighbourhood depth must be 1 to 3/)
    expect { build(identifier: 'AuditJob', depth: 0) }.to raise_error(Woods::Diagrams::InvalidRequest)
  end

  it 'keeps one direction, the types reached and the mechanisms asked for' do
    expect(build(identifier: 'Post', direction: 'dependents').text.lines.count { |l| l.include?('-->') }).to eq(3)
    expect(build(identifier: 'Post', direction: 'dependencies').text).not_to include('NotifyJob (job)"] -->')
    expect(build(identifier: 'Post', types: ['job']).text.scan('-->').size).to eq(2)
    expect(build(identifier: 'Post', via: ['belongs_to']).text.scan('-->').size).to eq(2)
    expect { build(identifier: 'Post', direction: 'sideways') }
      .to raise_error(Woods::Diagrams::InvalidRequest, /direction must be one of both, dependents, dependencies/)
  end

  it 'reads a graph from before typed edges: bare targets, reverse sources, arrows without a mechanism' do
    graph = File.join(diagram_root, 'payloads', 'gen-1', 'dependency_graph.json')
    data = JSON.parse(File.read(graph))
    bare_edges = data['edges'].transform_values { |list| list.map { |edge| edge['target'] } }
    legacy = data.slice('nodes', 'reverse').merge('edges' => bare_edges)
    File.write(graph, JSON.generate(legacy))
    expect(build(identifier: 'AuditJob').text).to eq(<<~MERMAID.chomp)
      flowchart LR
        #{node('AuditJob', 'job')}
        #{node('User', 'model')}
        #{node('NotifyJob', 'job')}
        #{id('AuditJob', 'job')} --> #{id('User', 'model')}
        #{id('NotifyJob', 'job')} --> #{id('AuditJob', 'job')}
        classDef focus stroke-width:3px
        class #{id('AuditJob', 'job')} focus
    MERMAID
  end

  it 'declares every unit once however many edges name it' do
    text = build(identifier: 'AuditJob', depth: 3).text
    declarations = text.lines.grep(/\A  n_\h+\[/).map { |line| line[/n_\h+/] }
    expect(declarations).to eq(declarations.uniq)
    expect(declarations.size).to eq(build(identifier: 'AuditJob', depth: 3).details['size'])
    expect(text.lines.grep(/-->/)).to all(match(/\A  n_\h+ -->(\|\w+\|)? n_\h+\n?\z/))
  end

  it 'refuses a neighbourhood over its node budget with its size, and draws nothing' do
    stub_const('Woods::Diagrams::Neighbourhood::NODE_BUDGET', 4)
    result = build(identifier: 'Post')
    expect([result.text, result.drawn?]).to eq([nil, false])
    expect(result.refusal).to eq('5 units is over the flowchart budget of 4; narrow the types or mechanisms to draw it')
    expect(build(identifier: 'Post', via: ['belongs_to'])).to be_drawn
  end
end
