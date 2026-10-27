# frozen_string_literal: true

require 'spec_helper'
require 'woods'
require 'woods/mcp/server'
require 'tmpdir'

RSpec.describe 'woods_status Git-enrichment summary' do
  let(:summary) do
    { 'version' => 1, 'state' => 'degraded', 'reason' => 'head_unresolvable', 'head_sha' => nil,
      'coverage' => { 'eligible_units' => 10, 'with_facts' => 4, 'history_unavailable' => 6,
                      'excluded' => { 'fileless' => 1, 'dependency_owned' => 2, 'source_missing' => 0 } },
      'capture' => { 'refreshed' => 0, 'retained' => 4 } }
  end

  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with('WOODS_NO_UPDATE_CHECK').and_return(nil)
  end

  def index_status(manifest)
    Dir.mktmpdir do |dir|
      reader = double('reader', manifest: manifest, source_freshness: { 'state' => 'current', 'complete' => true })
      return Woods::MCP::Server.build_status(reader: reader, retriever: nil, index_dir: dir).fetch(:index)
    end
  end

  it 'reports the summary published with the generation, without reading a unit or running git' do
    allow(Open3).to receive(:capture3).and_call_original
    reader = double('reader', manifest: { 'counts' => { 'service' => 10 }, 'git_enrichment' => summary },
                              source_freshness: { 'state' => 'current', 'complete' => true })
    allow(reader).to receive(:unit)

    index = Dir.mktmpdir do |dir|
      Woods::MCP::Server.build_status(reader: reader, retriever: nil, index_dir: dir).fetch(:index)
    end

    expect(index[:git_enrichment]).to eq(summary)
    expect(reader).not_to have_received(:unit)
  end

  it 'reports unknown, not healthy or zero, for a manifest written before the summary existed' do
    index = index_status('counts' => { 'service' => 10 }, 'git_sha' => 'a' * 40)

    expect(index[:git_enrichment]).to eq('state' => 'unknown', 'reason' => 'summary_missing')
  end

  it 'reports unknown for an unusable publication' do
    error = Woods::Generation::InvalidMarker.new('generation.json is unreadable')
    status = Woods::MCP::Server.degraded_status(error, nil, '/index', nil)

    expect(status.dig(:index, :git_enrichment)).to eq(state: 'unknown', reason: 'publication_unusable')
  end
end
