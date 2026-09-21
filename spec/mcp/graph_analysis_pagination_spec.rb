# frozen_string_literal: true

require 'spec_helper'
require 'woods/mcp/server'
require 'tmpdir'
require 'json'

RSpec.describe 'Graph analysis pagination' do
  around do |example|
    Dir.mktmpdir('woods-graph-pages') do |dir|
      @dir = dir
      File.write(File.join(dir, 'manifest.json'), '{}')
      analysis = {
        'orphans' => (1..25).map { |number| "Orphan#{number}" },
        'dead_ends' => (1..24).map { |number| "Leaf#{number}" },
        'stats' => { 'total_nodes' => 49 }
      }
      File.write(File.join(dir, 'graph_analysis.json'), JSON.generate(analysis))
      example.run
    end
  end

  def response(format, **arguments)
    server = Woods::MCP::Server.build(index_dir: @dir, response_format: format)
    server.instance_variable_get(:@tools).fetch('graph_analysis')
          .call(**arguments, server_context: {}).content.first.fetch(:text)
  end

  it 'enforces the advertised default for every section' do
    data = JSON.parse(response(:json))
    expect(data.fetch('orphans').size).to eq(20)
    expect(data.fetch('dead_ends').size).to eq(20)
    expect(data).to include('orphans_total' => 25, 'dead_ends_total' => 24)
  end

  it 'enforces the same default for a selected section' do
    data = JSON.parse(response(:json, analysis: 'orphans'))
    expect(data.fetch('orphans').size).to eq(20)
    expect(data).to include('orphans_total' => 25, 'orphans_truncated' => true)
  end

  [20, 100].each do |offset|
    it "retains total and offset on the JSON page at #{offset}" do
      data = JSON.parse(response(:json, analysis: 'orphans', limit: 5, offset: offset))
      expect(data).to include('orphans_total' => 25, 'orphans_offset' => offset, 'orphans_truncated' => true)
      expect(data.fetch('orphans')).to eq(offset == 20 ? (21..25).map { |n| "Orphan#{n}" } : [])
    end

    %i[markdown plain claude].each do |format|
      it "shows page context in #{format} at offset #{offset}" do
        text = response(format, analysis: 'orphans', limit: 5, offset: offset)
        expect(text).to match(/orphans/i)
        expect(text).to match(/showing #{offset == 20 ? 5 : 0} of 25 from offset #{offset}/i)
      end
    end
  end
end
