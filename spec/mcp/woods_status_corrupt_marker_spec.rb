# frozen_string_literal: true

require 'spec_helper'
require 'fileutils'
require 'tmpdir'
require 'woods'
require 'woods/mcp/server'
require 'woods/mcp/index_reader'

RSpec.describe 'woods_status with an unusable generation pointer' do
  let(:root) { Dir.mktmpdir('woods-status-corrupt') }
  let(:server) { Woods::MCP::Server.build(index_dir: root, warmup: false) }

  before { FileUtils.cp_r(Dir.glob(File.expand_path('../fixtures/woods/*', __dir__)), root) }
  after { FileUtils.rm_rf(root) }

  def call(name, **arguments)
    request = { jsonrpc: '2.0', id: 1, method: 'tools/call', params: { name: name, arguments: arguments } }
    JSON.parse(server.handle_json(JSON.generate(request))).fetch('result')
  end

  def status
    result = call('woods_status')
    expect(result['isError']).to be(false)
    JSON.parse(result.dig('content', 0, 'text'))
  end

  {
    'malformed JSON' => '{not json',
    'a non-object body' => '[]',
    'a non-integer number' => '{"number":"one","token":"t"}',
    'a payload path with a NUL byte' => "{\"number\":1,\"token\":\"t\",\"payload\":\"a\\u0000b\"}"
  }.each do |label, body|
    context "with #{label}" do
      before { File.write(File.join(root, 'generation.json'), body) }

      it 'answers a bounded degraded report with an actionable diagnostic' do
        report = status

        expect(report['ready']).to be(false)
        expect(report.dig('server', 'version')).to eq(Woods::VERSION)
        expect(report['index']).to include('state' => 'unusable_publication', 'error_code' => 'corrupt_artifact')
        expect(report.dig('index', 'diagnostic')).to include('woods:validate')
        expect(report.dig('index', 'incremental')).to include('ready' => false)
        expect(report.dig('index', 'history', 'state')).to eq('unknown')
        expect(JSON.generate(report).bytesize).to be < 8_192
      end

      it 'keeps refusing the lookup tool' do
        result = call('lookup', identifier: 'Post')

        expect(result['isError']).to be(true)
        expect(result.dig('_meta', 'error_code')).to eq('corrupt_artifact')
      end
    end
  end

  it 'reports a healthy pointer exactly as before' do
    File.write(File.join(root, 'generation.json'), '{"number":1,"token":"t"}')

    expect(status).not_to have_key('error_code')
    expect(status['index']).not_to include('state' => 'unusable_publication')
  end

  it 'does not raise from the status builder itself' do
    File.write(File.join(root, 'generation.json'), '{not json')
    reader = Woods::MCP::IndexReader.new(root)

    expect { Woods::MCP::Server.build_status(reader: reader, retriever: nil, index_dir: root) }.not_to raise_error
  end
end
