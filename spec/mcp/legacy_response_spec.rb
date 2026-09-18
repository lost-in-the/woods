# frozen_string_literal: true

require 'spec_helper'
require 'json'
require 'woods'
require 'woods/mcp/server'

RSpec.describe 'Legacy MCP structured error compatibility' do
  it 'preserves structured errors through the real SDK JSON-RPC dispatcher' do
    server = Woods::MCP::Server.build(index_dir: File.expand_path('../fixtures/woods', __dir__))
    request = { jsonrpc: '2.0', id: 1, method: 'tools/call',
                params: { name: 'lookup', arguments: { identifier: 'MissingLegacyUnit' } } }

    response = JSON.parse(server.handle_json(JSON.generate(request)))

    expect(response).not_to have_key('error')
    expect(response.fetch('result')).to include('isError' => true)
    expect(response.dig('result', '_meta')).to include('error_code' => 'not_found',
                                                       'identifier' => 'MissingLegacyUnit')
    expect(response.dig('result', 'content', 0, 'text')).to include('MissingLegacyUnit')
  end
end
