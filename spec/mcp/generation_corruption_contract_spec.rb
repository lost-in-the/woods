# frozen_string_literal: true

require 'spec_helper'
require 'fileutils'
require 'tmpdir'
require 'woods/mcp/server'

RSpec.describe 'Held-open MCP generation corruption' do
  let(:directory) { Dir.mktmpdir('woods-marker-contract') }
  let(:server) { Woods::MCP::Server.build(index_dir: directory, response_format: :json, warmup: false) }
  let(:marker_path) { File.join(directory, 'generation.json') }
  let(:metadata) do
    { 'io.modelcontextprotocol/protocolVersion' => '2026-07-28',
      'io.modelcontextprotocol/clientInfo' => { name: 'marker-spec', version: '1' },
      'io.modelcontextprotocol/clientCapabilities' => {} }
  end

  before do
    payload = File.join(directory, 'payloads', 'gen-1')
    FileUtils.mkdir_p(payload)
    FileUtils.cp_r(File.join(__dir__, '../fixtures/woods/.'), payload)
    Woods::Generation.new(output_dir: directory).bump!(reason: 'full', payload: 'payloads/gen-1')
  end

  after { FileUtils.remove_entry(directory) }

  def request(method, params)
    JSON.parse(server.handle_json(JSON.generate(jsonrpc: '2.0', id: 1, method: method,
                                                params: params.merge('_meta' => metadata))))
  end

  def tool(name, arguments = {})
    request('tools/call', name: name, arguments: arguments)
  end

  it 'does not silently serve a cached payload after its publication marker disappears' do
    expect(tool('lookup', identifier: 'Post').dig('result', 'isError')).not_to be(true)
    original = File.binread(marker_path)
    File.unlink(marker_path)
    2.times do
      expect(tool('lookup', identifier: 'Post').dig('result', '_meta', 'error_code')).to eq('corrupt_artifact')
      expect(request('resources/read', uri: 'codebase://manifest').dig('error', 'data', 'error_code'))
        .to eq('corrupt_artifact')
    end
    File.binwrite(marker_path, original)
    expect(tool('lookup', identifier: 'Post').dig('result', 'isError')).not_to be(true)
  end

  it 'releases a retention lock when marker corruption is detected after acquiring it' do
    reader = Woods::MCP::IndexReader.new(directory)
    reader.manifest
    generation = reader.instance_variable_get(:@generation)
    allow(generation).to receive(:current!).and_raise(Woods::Generation::InvalidMarker, 'marker changed during pin')

    expect { reader.with_pinned_generation { raise 'must not enter a corrupt generation' } }
      .to raise_error(Woods::Generation::InvalidMarker)
    File.open(File.join(directory, 'payloads/gen-1/manifest.json')) do |file|
      expect(file.flock(File::LOCK_EX | File::LOCK_NB)).not_to be(false)
    end
    expect(reader.instance_variable_get(:@pin_depth)).to eq(0)
    expect(reader.instance_variable_get(:@pin_owners)).to be_empty
    allow(generation).to receive(:current!).and_call_original
    expect(reader.with_pinned_generation { reader.manifest }).to be_a(Hash)
  end

  [JSON.generate(number: 2, payload: "payloads/\0bad"), 'not json', '[]', 'null', '{"number":2,"payload":42}',
   '{"number":{},"payload":"payloads/gen-1"}',
   '{"number":2,"token":[],"payload":"payloads/gen-1"}',
   '{"number":2,"payload":"payloads/missing"}',
   '{"number":2,"payload":"../outside"}'].each do |bad|
    it "returns stable errors and recovers on the same server after #{bad.inspect}" do
      expect(tool('lookup', identifier: 'Post').dig('result', 'isError')).not_to be(true)
      original = File.binread(marker_path)
      File.binwrite(marker_path, bad)
      2.times do
        { 'lookup' => { identifier: 'Post' }, 'search' => { query: 'Post' },
          'woods_status' => {}, 'trace_flow' => { entry_point: 'PostsController#show' } }.each do |name, args|
          response = tool(name, args)
          expect(response.dig('result', 'isError')).to be(true), response.inspect
          expect(response.dig('result', '_meta', 'error_code')).to eq('corrupt_artifact')
          expect(response.to_s).not_to include('NoMethodError', 'TypeError', 'backtrace')
        end
        %w[codebase://manifest codebase://graph codebase://unit/Post codebase://type/model].each do |uri|
          response = request('resources/read', uri: uri)
          expect(response.dig('error', 'data')).to include('error_code' => 'corrupt_artifact', 'uri' => uri)
        end
      end
      File.binwrite(marker_path, original)
      expect(tool('lookup', identifier: 'Post').dig('result', 'isError')).not_to be(true)
      expect(request('resources/read', uri: 'codebase://manifest').dig('result', 'contents')).not_to be_empty
    end
  end
end
