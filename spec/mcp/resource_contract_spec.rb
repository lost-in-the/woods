# frozen_string_literal: true

require 'spec_helper'
require 'fileutils'
require 'json'
require 'tmpdir'
require 'woods'
require 'woods/mcp/server'

RSpec.describe 'Index MCP resource contract' do
  let(:fixture_dir) { File.expand_path('../fixtures/woods', __dir__) }
  let(:tmpdir) { Dir.mktmpdir('woods-resource-contract') }
  let(:index_dir) { File.join(tmpdir, 'index') }
  let(:server) { Woods::MCP::Server.build(index_dir: index_dir, response_format: :json, warmup: false) }
  let(:resource_contract_meta) do
    {
      'io.modelcontextprotocol/protocolVersion' => '2026-07-28',
      'io.modelcontextprotocol/clientInfo' => { 'name' => 'resource-contract-spec', 'version' => '1.0' },
      'io.modelcontextprotocol/clientCapabilities' => {}
    }
  end

  before do
    FileUtils.mkdir_p(index_dir)
    FileUtils.cp_r(File.join(fixture_dir, '.'), index_dir)
  end

  after { FileUtils.rm_rf(tmpdir) }

  def rpc(method, params = {})
    params = params.merge('_meta' => resource_contract_meta)
    raw = server.handle_json(JSON.generate(jsonrpc: '2.0', id: 1, method: method, params: params))
    JSON.parse(raw)
  end

  def read(uri)
    rpc('resources/read', 'uri' => uri)
  end

  def expect_resource_not_found(response, uri)
    expect(response.dig('error', 'code')).to eq(-32_602)
    expect(response.dig('error', 'data', 'uri')).to eq(uri)
  end

  def expect_corrupt_artifact(response, uri)
    expect(response.dig('error', 'code')).to eq(-32_603)
    expect(response.dig('error', 'data')).to include(
      'uri' => uri,
      'error_code' => 'corrupt_artifact'
    )
  end

  it 'lists exactly both JSON resources and both JSON templates' do
    resources = rpc('resources/list').dig('result', 'resources')
    templates = rpc('resources/templates/list').dig('result', 'resourceTemplates')

    expect(resources.map { |resource| [resource.fetch('uri'), resource.fetch('mimeType')] }).to contain_exactly(
      ['codebase://manifest', 'application/json'],
      ['codebase://graph', 'application/json']
    )
    expect(templates.map { |template| [template.fetch('uriTemplate'), template.fetch('mimeType')] })
      .to contain_exactly(
        ['codebase://unit/{identifier}', 'application/json'],
        ['codebase://type/{type}', 'application/json']
      )
  end

  {
    'codebase://manifest' => ->(data) { data.fetch('total_units') },
    'codebase://graph' => ->(data) { data.fetch('nodes') },
    'codebase://unit/Post' => ->(data) { data.fetch('identifier') },
    'codebase://type/model' => ->(data) { data.fetch(0).fetch('identifier') }
  }.each do |uri, assertion|
    it "reads #{uri} as non-vacuous JSON with the declared MIME type" do
      content = read(uri).dig('result', 'contents', 0)
      data = JSON.parse(content.fetch('text'))

      expect(content).to include('uri' => uri, 'mimeType' => 'application/json')
      expect(assertion.call(data)).not_to be_nil
    end
  end

  it 'returns resource-not-found for missing unit and type template targets' do
    %w[codebase://unit/DoesNotExist codebase://type/does_not_exist].each do |uri|
      expect_resource_not_found(read(uri), uri)
    end
  end

  it 'returns a stable corrupt-artifact error when either static resource is missing' do
    server
    %w[manifest.json dependency_graph.json].each do |filename|
      original = File.join(index_dir, filename)
      parked = "#{original}.parked"
      FileUtils.mv(original, parked)
      uri = filename == 'manifest.json' ? 'codebase://manifest' : 'codebase://graph'

      expect_corrupt_artifact(read(uri), uri)
      FileUtils.mv(parked, original)
    end
  end

  it 'returns a stable corrupt-artifact error for malformed static and template JSON' do
    cases = {
      'manifest.json' => 'codebase://manifest',
      'dependency_graph.json' => 'codebase://graph',
      'models/_index.json' => 'codebase://type/model',
      'models/Post_a5554622.json' => 'codebase://unit/Post'
    }

    cases.each do |relative_path, uri|
      path = File.join(index_dir, relative_path)
      original = File.binread(path)
      File.binwrite(path, '{not-json')

      expect_corrupt_artifact(read(uri), uri)
      File.binwrite(path, original)
    end
  end

  it 'distinguishes an indexed unit with a missing backing file from an unknown unit' do
    server
    FileUtils.rm(File.join(index_dir, 'models/Post_a5554622.json'))

    expect_corrupt_artifact(read('codebase://unit/Post'), 'codebase://unit/Post')
    expect_resource_not_found(read('codebase://unit/DoesNotExist'), 'codebase://unit/DoesNotExist')
  end

  it 'rejects a warm cached unit after its manifest-known backing file is deleted' do
    expect(read('codebase://unit/Post').dig('result', 'contents')).not_to be_empty
    FileUtils.rm(File.join(index_dir, 'models/Post_a5554622.json'))

    expect_corrupt_artifact(read('codebase://unit/Post'), 'codebase://unit/Post')
  end

  it 'rejects a warm cached unit after its manifest-known backing file changes to corrupt JSON' do
    expect(read('codebase://unit/Post').dig('result', 'contents')).not_to be_empty
    File.binwrite(File.join(index_dir, 'models/Post_a5554622.json'), '{not-json')

    expect_corrupt_artifact(read('codebase://unit/Post'), 'codebase://unit/Post')
  end

  it 'rejects malformed resource URIs instead of returning text success' do
    uris = [
      'codebase://unit',
      'codebase://unit/',
      'codebase://type',
      'codebase://type/',
      'codebase://unit/%',
      'codebase://unit/Post?query=1',
      'codebase://unit/Post#fragment',
      'codebase:///unit/Post',
      'other://unit/Post'
    ]

    uris.each { |uri| expect_resource_not_found(read(uri), uri) }
  end

  it 'rejects traversal and encoded-separator attempts for both templates' do
    payloads = [
      '../manifest',
      '%2e%2e%2fmanifest',
      '%252e%252e%252fmanifest',
      '%2Fmanifest',
      '%5cmanifest'
    ]

    %w[unit type].product(payloads).each do |kind, payload|
      uri = "codebase://#{kind}/#{payload}"
      expect_resource_not_found(read(uri), uri)
    end
  end
end
