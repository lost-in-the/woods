# frozen_string_literal: true

require 'spec_helper'
require 'json'
require 'woods'
require 'woods/mcp/server'

RSpec.describe Woods::MCP::VersionAwareToolDispatch do
  let(:fixture_dir) { File.expand_path('../fixtures/woods', __dir__) }
  let(:server) { Woods::MCP::Server.build(index_dir: fixture_dir, warmup: false) }

  # Drive a tools/call through the real JSON-RPC entry point (what the stdio and
  # HTTP transports use), so instrumentation/session setup happens exactly as in
  # production. RequestHandlerError is caught and serialized into the response's
  # `error` object — the gem places the detailed text in `error.data`.
  def tools_call(name, arguments: {})
    request = JSON.generate(
      jsonrpc: '2.0', id: 1, method: 'tools/call',
      params: { name: name, arguments: arguments }
    )
    JSON.parse(server.handle_json(request))
  end

  describe 'calling a tool that the installed gem does not define' do
    it 'returns version-aware guidance instead of a bare "Tool not found"' do
      response = tools_call('a_tool_from_the_future')

      detail = response.dig('error', 'data')
      expect(detail).to include('a_tool_from_the_future')
      expect(detail).to include(Woods::VERSION)
      expect(detail).to include('bundle update woods')
    end

    it 'appends the latest published version when the update cache knows one' do
      allow(Woods::UpdateCheck).to receive(:fetch_latest_version).and_return('999.0.0')
      Woods::UpdateCheck.check # prime the cache the (cache-only) error path reads

      detail = tools_call('ghost_tool').dig('error', 'data')
      expect(detail).to include('999.0.0')
    end
  end

  describe 'a tool the installed gem does define' do
    it 'dispatches normally (the override delegates to super)' do
      response = tools_call('woods_status')

      expect(response).to have_key('result')
      expect(response).not_to have_key('error')
    end
  end
end
