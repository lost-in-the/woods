# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'woods'
require 'woods/mcp/server'

RSpec.describe 'Traversal response scope and totals' do
  let(:directory) { Dir.mktmpdir('woods-traversal-response') }

  before do
    Woods.configuration = Woods::Configuration.new
    File.write(File.join(directory, 'manifest.json'), JSON.generate(total_units: 0))
    peers = %w[Peer1 Peer2 Peer3 Peer4 Peer5 Peer6]
    nodes = %w[Hub Isolated].to_h { |id| [id, { type: 'poro' }] }
    peers.each { |id| nodes[id] = { type: 'service' } }
    edges = peers.to_h { |id| [id, [{ target: 'Hub', via: 'code_reference' }]] }
    edges['Hub'] = peers.map { |id| { target: id, via: 'code_reference' } }
    reverse = peers.to_h { |id| [id, ['Hub']] }.merge('Hub' => peers)
    nodes['Domain::Vendor::PlanChange'] = { type: 'poro' }
    nodes['spec/models/domain/vendor/plan_change_spec.rb'] = { type: 'test_mapping' }
    edges['spec/models/domain/vendor/plan_change_spec.rb'] =
      [{ target: 'Domain::Vendor::PlanChange', via: 'test_coverage' }]
    reverse['Domain::Vendor::PlanChange'] = ['spec/models/domain/vendor/plan_change_spec.rb']
    File.write(File.join(directory, 'dependency_graph.json'),
               JSON.generate(nodes: nodes, edges: edges, reverse: reverse))
  end

  after { FileUtils.remove_entry(directory) }

  def call_tool(name, format: :json, **arguments)
    server = Woods::MCP::Server.build(index_dir: directory, response_format: format, warmup: false)
    request = { jsonrpc: '2.0', id: 1, method: 'tools/call', params: { name: name, arguments: arguments } }
    result = JSON.parse(server.handle_json(JSON.generate(request))).fetch('result')
    expect(result['isError']).not_to be(true)
    text = result.fetch('content').first.fetch('text')
    format == :json ? JSON.parse(text) : text
  end

  def traverse(name, **arguments)
    Woods::MCP::IndexReader.new(directory).public_send("traverse_#{name}", 'Hub', depth: 1, **arguments)
  end

  %w[dependencies dependents].each do |name|
    [false, true].each do |explain|
      context "#{name}, explain=#{explain}" do
        it 'discloses recorded graph scope on complete, root-only and empty pages' do
          [{ identifier: 'Hub' }, { identifier: 'Isolated' }, { identifier: 'Domain::Vendor::PlanChange' },
           { identifier: 'Hub', offset: 9 }].each do |arguments|
            data = call_tool(name, explain: explain, **arguments)
            expect(data).to include('total_is_exact' => true)
            expect(data.fetch('graph_coverage')).to include('scope' => 'published_relationships',
                                                            'source_references' => 'not_exhaustive')
            expect(data.dig('graph_coverage', 'notice')).to include('method-body constant references', 'do not prove')
            next unless explain && arguments[:identifier] == 'Domain::Vendor::PlanChange'

            expect(data.dig('explanation', 'witnesses', 'Domain::Vendor::PlanChange',
                            'typed_path_complete')).to be(true)
          end
        end

        it 'preserves budget prefixes, counters and witnesses on every page without an extra walk' do
          { node_budget: { max_nodes: 4 }, edge_budget: { max_edges: 2 } }.each do |reason, budget|
            baseline = traverse(name, explain: explain, **budget)
            total = baseline.fetch(:nodes).size
            [{ limit: 2 }, { limit: 2, offset: 2 }, { offset: total }, { limit: 20 }].each do |page|
              data = call_tool(name, identifier: 'Hub', depth: 1, explain: explain, **budget, **page)
              expect(data).to include('partial' => true, 'partial_reason' => reason.to_s, 'total_is_exact' => false)
              expected_nodes = baseline[:nodes].to_a.drop(page.fetch(:offset, 0)).take(page.fetch(:limit, 50)).to_h
              expect(data['nodes']).to eq(JSON.parse(JSON.generate(expected_nodes)))
              expect(data['traversal_budget']).to eq(JSON.parse(JSON.generate(baseline.fetch(:traversal_budget))))
              paged = page.fetch(:offset, 0).positive? || total > page.fetch(:limit, 50)
              expect(data['nodes_total']).to eq(total) if paged
              next unless explain

              data.dig('explanation', 'witnesses').each do |id, witness|
                original = baseline.dig(:explanation, :witnesses, id)
                expected = JSON.parse(JSON.generate(original)).except('context')
                expect(witness.except('context')).to eq(expected)
              end
            end
          end
        end

        it 'keeps filtered budget cutoffs inexact and retains charged work' do
          [{ types: ['missing'] }, { via: ['missing'] },
           { types: ['service'], via: ['code_reference'] }].each do |scope|
            baseline = traverse(name, max_edges: 2, explain: explain, **scope)
            data = call_tool(name, identifier: 'Hub', depth: 1, max_edges: 2, explain: explain, **scope)
            expect(data).to include('partial' => true, 'partial_reason' => 'edge_budget', 'total_is_exact' => false)
            expect(data['nodes']).to eq(JSON.parse(JSON.generate(baseline.fetch(:nodes))))
            expect(data['traversal_budget']).to eq(JSON.parse(JSON.generate(baseline.fetch(:traversal_budget))))
          end
        end

        it 'annotates the result of exactly one bounded walk' do
          expect_any_instance_of(Woods::MCP::IndexReader).to receive("traverse_#{name}").once.and_call_original
          call_tool(name, identifier: 'Hub', max_nodes: 2, offset: 9, explain: explain)
        end

        it 'keeps completed exact-budget and filtered totals exact despite pagination' do
          [{ max_nodes: 7, max_edges: name == 'dependents' && explain ? 12 : 6 }, { types: ['service'] },
           { via: 'missing' }].each do |scope|
            [{ limit: 2 }, { limit: 2, offset: 6 }, { offset: 9 }, { limit: 20 }].each do |page|
              data = call_tool(name, identifier: 'Hub', depth: 1, explain: explain, **scope, **page)
              expect(data).to include('total_is_exact' => true)
              expect(data).not_to have_key('partial')
            end
          end
        end

        %i[markdown plain claude].each do |format|
          it "discloses coverage and lower-bound budget totals in #{format}, including empty and unpaged answers" do
            { node_budget: { max_nodes: 4 }, edge_budget: { max_edges: 2 } }.each do |reason, budget|
              total = if reason == :node_budget
                        4
                      else
                        (name == 'dependents' && explain ? 2 : 3)
                      end
              [{ limit: 2 }, { limit: 2, offset: 2 }, { offset: total }, { limit: 20 }].each do |page|
                text = call_tool(name, format: format, identifier: 'Hub', depth: 1, explain: explain, **budget, **page)
                expect(text).to include('Graph coverage: published relationships only.', "of at least #{total}",
                                        "total unknown: #{reason}")
                expect(text).not_to match(/(?:Showing|showing) \d+ of #{total}(?: |;)/)
                expect(text).not_to include('typed path complete=')
              end
            end
            %w[Hub Isolated Domain::Vendor::PlanChange].each do |identifier|
              text = call_tool(name, format: format, identifier: identifier, explain: explain)
              expect(text).to include('Graph coverage: published relationships only.')
              expect(text).not_to include('total unknown:')
              expect(text).to include('witness types unambiguous=yes') if explain
            end
            text = call_tool(name, format: format, identifier: 'Hub', offset: 9, explain: explain)
            expect(text).to include('Graph coverage: published relationships only.')
          end
        end
      end
    end
  end
end
