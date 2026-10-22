# frozen_string_literal: true

require 'spec_helper'
require 'woods/impact/renderers'
require 'woods/impact/value'
require 'cgi'

RSpec.describe Woods::Impact::Renderers do
  def identity(identifier = 'Shared', type = 'model')
    { 'identifier' => identifier, 'type' => type }
  end

  def provenance(side, generation)
    { 'endpoint' => side, 'generation' => generation }
  end

  def data
    changed = identity.merge('status' => 'modified', 'facets' => ['source'], 'categories' => ['behaviour'])
    edge = { 'source' => identity('Caller', 'service'), 'target' => identity, 'via' => 'code_reference' }
    path = provenance('to', 2).merge('root' => identity, 'edges' => [edge])
    {
      'schema_version' => 1,
      'range' => { 'from' => { 'generation' => 1 }, 'to' => { 'generation' => 2 } },
      'parameters' => { 'mode' => 'range', 'depth' => 2 },
      'coverage' => { 'complete' => false, 'affected' => 'bounded', 'flows' => 'partial', 'risks' => 'not_computed' },
      'changed' => [changed],
      'affected' => [identity('Caller', 'service').merge(provenance('to', 2)).merge(
        'distance' => 1, 'weight' => 0.5, 'paths' => [path]
      )],
      'flows' => [{ 'entry_point' => 'ItemsController#show', 'route' => { 'verb' => 'GET', 'path' => '/items' },
                    'endpoint' => 'to', 'generation' => 2 }],
      'risks' => [], 'tests' => [],
      'unknowns' => [{ 'kind' => 'expanded_membership_only', 'endpoint' => 'to', 'generation' => 2 }]
    }
  end

  it 'renders both formats from the same immutable report without changing its values' do
    frozen = Woods::Impact::Value.copy(data)
    report = double('report', to_h: frozen)
    original = JSON.generate(frozen)
    markdown = described_class.markdown(report)
    mermaid = described_class.mermaid(report)
    expect(markdown).to include('Incomplete report', '1 unknown records', 'gen:1', 'gen:2', 'Shared', 'Caller')
    expect(CGI.unescapeHTML(markdown)).to include('source', 'behaviour', 'GET /items', 'not_computed')
    expect(mermaid).to start_with("flowchart LR\n")
    expect(mermaid).to include('Shared', 'Caller', 'code_reference', 'to gen:2', '1 unknown records')
    summary = mermaid.lines.find { |line| line.start_with?('report_summary[') }
    expect(summary).to include('Incomplete report', '1 unknown records')
    expect(JSON.generate(frozen)).to eq(original)
    expect(described_class.markdown(report)).to eq(markdown)
    expect(described_class.mermaid(report)).to eq(mermaid)
  end

  it 'bounds Markdown near 60 lines and explicitly accounts for collapsed and omitted entries' do
    value = data
    %w[changed affected flows risks tests unknowns].each do |key|
      value[key] = Array.new(100) { |index| value[key].first || identity("Example#{index}", 'test_mapping') }
    end
    output = described_class.markdown(value)
    expect(output.lines.size).to be <= 60
    expect(output).to include('<details><summary>', 'more entries', 'omitted; see JSON')
    expect(output).to include('100 unknown records')
  end

  it 'escapes arbitrary Markdown identifiers without adding raw HTML, tables, links or injected lines' do
    value = data
    value['changed'].first['identifier'] = "[x](https://invalid.test)|`<script>\n# injected"
    output = described_class.markdown(value)
    expect(output).not_to include('<script>', '[x](', '|`', "\n# injected")
    expect(output).not_to include('https://')
    expect(output).to include('&#91;', '&#124;', '&#96;', '&#60;', '&#10;')
  end

  it 'keeps equal names distinct by actual type and endpoint generation in Mermaid' do
    value = data
    value['changed'] << identity('Shared', 'service').merge('status' => 'removed', 'facets' => ['source'],
                                                            'categories' => [])
    value['affected'] << identity('Caller', 'service').merge(provenance('from', 1)).merge(
      'distance' => 1, 'weight' => nil, 'paths' => [provenance('from', 1).merge(
        'root' => identity('Shared', 'service'), 'edges' => [
          { 'source' => identity('Caller', 'service'), 'target' => identity('Shared', 'service'), 'via' => 'old' }
        ]
      )]
    )
    output = described_class.mermaid(value)
    nodes = output.lines.grep(/\An\d+\[/)
    expect(nodes.size).to eq(4)
    expect(output).to include('from gen:1', 'to gen:2', 'model', 'service')
    expect(output.lines.grep(/ -->/).size).to eq(2)
  end

  it 'escapes Mermaid label syntax and refuses cross-generation witness contexts' do
    value = data
    value['affected'].first['paths'].first['edges'].first['via'] = "\"] --> injected[\"<b>|\nclick evil"
    output = described_class.mermaid(value)
    expect(output).not_to include('] --> injected', '<b>', "\nclick evil")
    expect(output).to include('#34;', '#124;', '#10;')
    value['affected'].first['paths'].first['generation'] = 1
    expect { described_class.mermaid(value) }.to raise_error(ArgumentError, /context/)
  end

  it 'bounds Mermaid output while preserving an explicit truncation marker' do
    value = data
    value['changed'] = Array.new(100) do |index|
      identity("Example#{index}").merge('status' => 'modified', 'facets' => ['source'], 'categories' => [])
    end
    output = described_class.mermaid(value)
    expect(output.lines.grep(/\An\d+\[/).size).to be <= 60
    expect(output).to include('Truncated')
    expect(output).to include('Incomplete report', '1 unknown records')
  end

  it 'bounds Mermaid witness edges and exposes truncation in its visible coverage note' do
    value = data
    original = value['affected'].first['paths'].first
    value['affected'].first['paths'] = Array.new(200) do |index|
      original.merge('edges' => [original['edges'].first.merge('via' => "relationship_#{index}")])
    end
    output = described_class.mermaid(value)
    expect(output.lines.grep(/ -->/).size).to eq(120)
    expect(output.lines.find { |line| line.start_with?('report_summary[') }).to include('Truncated display')
  end

  it 'renders explicit no-range focus roots without fabricating changes or a base generation' do
    value = data.merge('range' => nil, 'changed' => [], 'focus' => [identity], 'endpoint' => { 'generation' => 2 })
    value['parameters'] = { 'mode' => 'focus', 'depth' => 2 }
    markdown = described_class.markdown(value)
    mermaid = described_class.mermaid(value)
    expect(CGI.unescapeHTML(markdown)).to include('Focus: 1 typed roots at gen:2', 'Shared [model]')
    expect(markdown).not_to include('Range: gen:', 'gen:1')
    expect(mermaid).to include('Shared', 'focus', 'to gen:2')
    expect(mermaid).not_to include('from gen:')
  end

  it 'rejects unsupported schema versions rather than silently rendering a partial shape' do
    value = data.merge('schema_version' => 9)
    expect { described_class.markdown(value) }.to raise_error(ArgumentError, /schema/)
    expect { described_class.mermaid(value) }.to raise_error(ArgumentError, /schema/)
  end
end
