# frozen_string_literal: true

require 'spec_helper'
require 'json'
require 'tmpdir'
require 'fileutils'
require 'woods/svelte_flow/standalone_renderer'

RSpec.describe Woods::SvelteFlow::StandaloneRenderer do
  around do |example|
    Dir.mktmpdir do |dir|
      @build_dir = dir
      File.write(File.join(dir, 'app.js'), 'console.log("app");')
      File.write(File.join(dir, 'app.css'), '.node { color: red; }')
      example.run
    end
  end

  subject(:renderer) { described_class.new(build_dir: @build_dir) }

  let(:graph) { { 'nodes' => [{ 'id' => 'Order' }], 'edges' => [] } }

  it 'inlines the graph payload, css, and js into one document' do
    html = renderer.render(graph: graph, sources: {}, title: 'Woods — Order')
    expect(html).to include('window.__WOODS_SUBGRAPH__ =')
    expect(html).to include('.node { color: red; }')
    expect(html).to include('console.log("app");')
    expect(html).to include('<title>Woods — Order</title>')
  end

  it 'round-trips the graph through the inlined JSON' do
    html = renderer.render(graph: graph, sources: {}, title: 't')
    json = html[/window\.__WOODS_SUBGRAPH__ = (\{.*?\});/m, 1]
    expect(JSON.parse(json)['graph']['nodes'].first['id']).to eq('Order')
  end

  it 'neutralizes a </script> sequence inside inlined source' do
    sources = { 'X' => { 'sourceCode' => 'a = "</script>"' } }
    html = renderer.render(graph: graph, sources: sources, title: 't')
    expect(html).not_to include('</script>"')
    expect(html).to include('<\\/script>')
  end

  it 'escapes HTML in the title' do
    html = renderer.render(graph: graph, sources: {}, title: '<b>x</b>')
    expect(html).to include('<title>&lt;b&gt;x&lt;/b&gt;</title>')
  end
end
