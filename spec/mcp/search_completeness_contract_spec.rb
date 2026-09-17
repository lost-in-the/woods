# frozen_string_literal: true

require 'spec_helper'
require 'fileutils'
require 'tmpdir'
require 'woods'
require 'woods/mcp/server'

RSpec.describe 'MCP search completeness contract' do
  let(:directory) { Dir.mktmpdir('woods-search-contract') }

  before do
    FileUtils.cp_r(File.join(File.expand_path('../fixtures/woods', __dir__), '.'), directory)
    Woods.configuration = Woods::Configuration.new
  end
  after { FileUtils.remove_entry(directory) }

  def call_search(format: :json, **arguments)
    server = Woods::MCP::Server.build(index_dir: directory, response_format: format, warmup: false)
    meta = {
      'io.modelcontextprotocol/protocolVersion' => '2026-07-28',
      'io.modelcontextprotocol/clientInfo' => { name: 'completeness-contract', version: '1' },
      'io.modelcontextprotocol/clientCapabilities' => {}
    }
    request = { jsonrpc: '2.0', id: 1, method: 'tools/call',
                params: { name: 'search', arguments: arguments, _meta: meta } }
    JSON.parse(server.handle_json(JSON.generate(request))).fetch('result')
  end

  it 'retains existing JSON fields while distinguishing a returned prefix from an exact total' do
    result = call_search(query: '.', limit: 2)
    payload = result.dig('structuredContent', 'data')

    expect(result['isError']).to be(false)
    expect(payload).to include('query' => '.', 'result_count' => 2, 'partial' => true)
    expect(payload['results'].size).to eq(2)
    expect(payload['completeness']).to eq('status' => 'partial', 'reason' => 'result_limit', 'has_more' => true,
                                          'total_matches' => nil, 'matched_lower_bound' => 3)
    expect(payload['hint']).to include('Narrow')
  end

  it 'reports an exact-limit exhausted result as complete through the wire' do
    payload = call_search(query: '.', types: ['model'], limit: 2).dig('structuredContent', 'data')

    expect(payload['completeness']).to include('status' => 'complete', 'reason' => 'exhausted',
                                               'has_more' => false, 'total_matches' => 2)
    expect(payload).not_to have_key('partial')
  end

  %i[markdown plain claude].each do |format|
    it "reports truncation and unknown total in #{format} without presenting returned count as exhaustive" do
      text = call_search(format: format, query: '.', limit: 2).dig('structuredContent', 'text')

      expect(text).to include('2 results returned', 'partial (result_limit)', 'More matches: yes',
                              'total matches: unknown', 'matched lower bound: 3', 'Narrow')
    end

    it "reports exact totals when exhausted in #{format}" do
      text = call_search(format: format, query: '.', types: ['model'], limit: 2).dig('structuredContent', 'text')

      expect(text).to include('complete (exhausted)', 'More matches: no', 'total matches: 2')
    end
  end

  it 'preserves corrupt-artifact errors and marks completeness unknown' do
    File.write(File.join(directory, 'models', '_index.json'), '{broken')

    result = call_search(query: '.', limit: 2)

    expect(result['isError']).to be(true)
    expect(result['_meta']).to include('error_code' => 'corrupt_artifact', 'tool' => 'search')
    expect(result.dig('_meta', 'completeness')).to include('status' => 'unknown',
                                                           'reason' => 'unreadable_or_corrupt_source',
                                                           'has_more' => nil, 'total_matches' => nil)
    expect(result.dig('structuredContent', 'text')).to include('Search completeness: unknown')
    expect(result['structuredContent']).not_to have_key('data')
  end

  %i[json markdown plain claude].each do |format|
    it "keeps additional-match knowledge unknown at a scan cutoff in #{format}" do
      previous = ENV.fetch('WOODS_SEARCH_MAX_SCAN', nil)
      ENV['WOODS_SEARCH_MAX_SCAN'] = '1'
      result = call_search(format: format, query: 'has_many', fields: ['source_code'], types: ['model'], limit: 1)

      if format == :json
        expect(result.dig('structuredContent', 'data', 'completeness'))
          .to include('reason' => 'scan_budget', 'has_more' => nil, 'total_matches' => nil, 'matched_lower_bound' => 1)
      else
        expect(result.dig('structuredContent', 'text'))
          .to include('partial (scan_budget)', 'More matches: unknown', 'total matches: unknown',
                      'matched lower bound: 1')
      end
    ensure
      ENV['WOODS_SEARCH_MAX_SCAN'] = previous
    end
  end
end
