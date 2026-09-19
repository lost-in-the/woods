# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'woods'
require 'woods/mcp/server'

RSpec.describe 'Traversal structured responses' do
  let(:directory) { Dir.mktmpdir('woods-traversal-wire') }

  before do
    Woods.configuration = Woods::Configuration.new
    File.write(File.join(directory, 'manifest.json'), JSON.generate(total_units: 0))
    nodes = %w[Hub A B C Isolated].to_h { |id| [id, { type: 'poro' }] }
    edges = { 'Hub' => %w[A B C].map { |id| { target: id, via: 'code_reference' } } }
    %w[A B C].each { |id| edges[id] = [{ target: 'Hub', via: 'code_reference' }] }
    reverse = { 'Hub' => %w[A B C] }.merge(%w[A B C].to_h { |id| [id, ['Hub']] })
    File.write(File.join(directory, 'dependency_graph.json'),
               JSON.generate(nodes: nodes, edges: edges, reverse: reverse))
  end

  after { FileUtils.remove_entry(directory) }

  def request(server, method, params)
    JSON.parse(server.handle_json(JSON.generate(jsonrpc: '2.0', id: 1, method: method, params: params))).fetch('result')
  end

  %i[json markdown plain claude].each do |format|
    %w[dependencies dependents].each do |name|
      [false, true].each do |explain|
        it "preserves the paginated payload and rendered text for #{format} #{name}, explain=#{explain}" do
          server = Woods::MCP::Server.build(index_dir: directory, response_format: format, warmup: false)
          tool = request(server, 'tools/list', {}).fetch('tools').find { |item| item['name'] == name }
          expect(tool.fetch('inputSchema').fetch('properties')).not_to have_key('format')
          schema = MCP::Tool::OutputSchema.new(tool.fetch('outputSchema'))
          reader = Woods::MCP::IndexReader.new(directory)
          renderer = Woods::MCP::ToolResponseRenderer.for(format)
          [{}, { limit: 1 }, { max_nodes: 2, limit: 1 }, { max_edges: 1, offset: 9 },
           { max_edges: 1, types: ['missing'] }, { identifier: 'Isolated' }, { identifier: 'Absent' }].each do |options|
            arguments = { identifier: 'Hub', depth: 1, explain: explain }.merge(options)
            traversal_options = { depth: 1, explain: explain, types: options[:types],
                                  max_nodes: options.fetch(:max_nodes, 1000),
                                  max_edges: options.fetch(:max_edges, 10_000) }
            raw = reader.public_send("traverse_#{name}", arguments[:identifier], **traversal_options)
            if raw[:found] == false
              raw[:message] =
                "Identifier 'Absent' not found in the index. Use 'search' to find valid identifiers."
            end
            Woods::MCP::TraversalResponse.annotate(raw)
            Woods::MCP::Server.send(:paginate_traversal_nodes, raw, options.fetch(:limit, 50),
                                    options.fetch(:offset, 0))
            Woods::MCP::TraversalEvidencePage.apply(raw)
            response = request(server, 'tools/call', name: name, arguments: arguments)
            expected = JSON.parse(JSON.generate(raw))
            expect(response['isError']).to be(false)
            expect(response.dig('structuredContent', 'data')).to eq(expected)
            expect(response.dig('content', 0, 'text')).to eq(renderer.render(name.to_sym, raw))
            expect(response.dig('structuredContent', 'text')).to eq(response.dig('content', 0, 'text'))
            expect { schema.validate_result(response.fetch('structuredContent')) }.not_to raise_error
            expect(JSON.parse(response.dig('content', 0, 'text'))).to eq(expected) if format == :json
          end
        end
      end
    end
  end

  it 'keeps argument and corrupt-artifact errors separate from traversal data' do
    server = Woods::MCP::Server.build(index_dir: directory, warmup: false)
    %w[dependencies dependents].each do |name|
      response = request(server, 'tools/call', name: name, arguments: { identifier: 'Hub', format: 'json' })
      expect(response['isError']).to be(true)
      expect(response.dig('_meta', 'error_code')).to eq('invalid_arguments')
      expect(response.fetch('structuredContent')).not_to have_key('data')
    end
    File.write(File.join(directory, 'dependency_graph.json'), '{broken')
    %w[dependencies dependents].each do |name|
      response = request(server, 'tools/call', name: name, arguments: { identifier: 'Hub' })
      expect(response['isError']).to be(true)
      expect(response.dig('_meta', 'error_code')).to eq('corrupt_artifact')
      expect(response.fetch('structuredContent')).not_to have_key('data')
    end
  end

  it 'retains the existing text-only and parsed-JSON defaults for other tool responses' do
    %i[markdown json].each do |format|
      server = Woods::MCP::Server.build(index_dir: directory, response_format: format, warmup: false)
      response = request(server, 'tools/call', name: 'structure', arguments: {})
      text = response.dig('content', 0, 'text')
      expect(response.dig('structuredContent', 'text')).to eq(text)
      if format == :json
        expect(response.dig('structuredContent', 'data')).to eq(JSON.parse(text))
      else
        expect(response.fetch('structuredContent')).not_to have_key('data')
      end
    end
  end
end
