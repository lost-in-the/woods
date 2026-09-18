# frozen_string_literal: true

require 'spec_helper'
require 'woods'
require 'tmpdir'
require 'fileutils'
require 'woods/mcp/server'
require 'woods/mcp/published_lexical_retriever'
require 'woods/filename_utils'

RSpec.describe 'Published scoped discovery and retrieval' do
  include Woods::FilenameUtils

  let(:index_dir) { Dir.mktmpdir('woods-scoped-search') }
  let(:reader) { Woods::MCP::IndexReader.new(index_dir) }

  before do
    Woods.configuration = Woods::Configuration.new
    File.write(File.join(index_dir, 'manifest.json'), '{}')
  end
  after { FileUtils.remove_entry(index_dir) }

  def publish(identifier, package:, path: nil, type: 'model', source: 'needle')
    dir = type == 'gem_source' ? 'rails_source' : Woods::MCP::IndexReader::TYPE_TO_DIR.fetch(type)
    directory = File.join(index_dir, dir)
    FileUtils.mkdir_p(directory)
    unit = { identifier: identifier, type: type, file_path: path || "#{package}/app/#{identifier}.rb",
             source_code: source, metadata: { package: package } }
    File.write(File.join(directory, collision_safe_filename(identifier)), JSON.generate(unit))
    index = File.join(directory, '_index.json')
    entries = File.exist?(index) ? JSON.parse(File.read(index)) : []
    File.write(index, JSON.generate(entries + [{ identifier: identifier }]))
  end

  def call_tool(name, **args)
    retriever = Woods::MCP::PublishedLexicalRetriever.new(index_dir: index_dir)
    server = Woods::MCP::Server.build(index_dir: index_dir, retriever: retriever, warmup: false, response_format: :json)
    raw = server.handle_json(JSON.generate(jsonrpc: '2.0', id: 1, method: 'tools/call',
                                           params: { name: name, arguments: args }))
    response = JSON.parse(raw, symbolize_names: true)
    expect(response).not_to have_key(:error)
    response.fetch(:result)
  end

  it 'applies package eligibility before identifier and deep result limits' do
    25.times { |i| publish("NeedleNoise#{i}", package: 'packs/other') }
    publish('NeedleInvoice', package: 'packs/billing')
    %w[identifier source_code metadata].each do |field|
      query = field == 'metadata' ? 'billing' : 'needle'
      result = reader.search(query, packages: ['packs/billing'], fields: [field], limit: 1)
      expect(result[:results].map { |unit| unit[:identifier] }).to eq(['NeedleInvoice'])
      expect(result[:applied_scope]).to include(eligible_units: 1)
      expect(result[:completeness]).to include(status: 'complete', total_matches: 1)
    end
  end

  it 'distinguishes path segment neighbors and honors actual mixed-directory unit types' do
    publish('Invoice', package: 'packs/billing')
    publish('Admin', package: 'packs/billing_admin')
    publish('Widget', package: 'packs/billing', type: 'gem_source')
    result = reader.search('.*', source_paths: ['packs/billing'], types: ['gem_source'])
    expect(result[:results]).to eq([{ identifier: 'Widget', type: 'gem_source', match_field: 'identifier' }])
    expect(result[:applied_scope]).to include(eligible_units: 1)
  end

  it 'reports an empty path scope separately from a populated scope with no matches' do
    publish('Invoice', package: 'packs/billing')
    empty = reader.search('needle', source_paths: ['packs/missing'])
    no_match = reader.search('zzzzz', packages: ['packs/billing'])
    expect(empty[:applied_scope]).to include(eligible_units: 0)
    expect(no_match[:applied_scope]).to include(eligible_units: 1)
    expect([empty, no_match].map { |result| result[:completeness][:total_matches] }).to eq([0, 0])
  end

  it 'keeps completeness unknown when scoped deep matching consumes its scan budget' do
    publish('First', package: 'packs/billing', source: 'hay')
    publish('Second', package: 'packs/billing')
    original = ENV.fetch('WOODS_SEARCH_MAX_SCAN', nil)
    ENV['WOODS_SEARCH_MAX_SCAN'] = '1'
    result = reader.search('needle', packages: ['packs/billing'], fields: ['source_code'])
    expect(result[:completeness]).to include(status: 'partial', reason: 'scan_budget', has_more: nil)
    expect(result[:applied_scope]).to include(eligible_units: 2)
  ensure
    ENV['WOODS_SEARCH_MAX_SCAN'] = original
  end

  it 'exposes applied scope on retrieval structured output without hiding source provenance' do
    publish('Invoice', package: 'packs/billing')
    response = call_tool('codebase_retrieve', query: 'needle', packages: ['packs/billing'])
    expect(response[:structuredContent][:data][:applied_scope]).to include(eligible_units: 1, outcome: 'matched')
    expect(response[:structuredContent][:data][:sources]).to include(include(identifier: 'Invoice', type: 'model'))
  end

  it 'returns typed errors for unknown package and out-of-root path requests' do
    publish('Invoice', package: 'packs/billing')
    %w[search codebase_retrieve].each do |name|
      response = call_tool(name, query: 'needle', packages: ['unknown'])
      expect(response[:_meta]).to include(error_code: 'unsupported_argument', argument: 'scope')
      response = call_tool(name, query: 'needle', source_paths: ['../outside'])
      expect(response[:isError]).to be(true)
    end
  end
end
