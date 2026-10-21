# frozen_string_literal: true

require 'spec_helper'
require 'json'
require 'woods'
require 'woods/extracted_unit'
require 'woods/dependency_graph'
require 'woods/mcp/server'

RSpec.describe 'pagerank tool with documentation units' do
  let(:fixture_dir) { File.expand_path('../fixtures/woods', __dir__) }

  def unit(type, identifier, dependencies = [])
    Woods::ExtractedUnit.new(type: type, identifier: identifier, file_path: "/app/#{identifier}").tap do |extracted|
      extracted.dependencies = dependencies
    end
  end

  let(:graph) do
    Woods::DependencyGraph.new.tap do |built|
      [unit(:model, 'Ledger'),
       unit(:service, 'Ledger::Poster', [{ type: :model, target: 'Ledger', via: :code_reference }]),
       unit(:doc, 'docs/ledger.md', [{ type: :model, target: 'Ledger', via: :documents }]),
       unit(:doc, 'README.md')].each { |extracted| built.register(extracted) }
    end
  end

  it 'counts only the ranked nodes in its header' do
    allow_any_instance_of(Woods::MCP::IndexReader).to receive(:dependency_graph).and_return(graph)
    server = Woods::MCP::Server.build(index_dir: fixture_dir, response_format: :json, warmup: false)

    response = server.instance_variable_get(:@tools)['pagerank'].call(server_context: {})
    data = JSON.parse(response.content.first[:text])

    expect(data['total_nodes']).to eq(2)
  end
end
