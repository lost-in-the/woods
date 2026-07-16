# frozen_string_literal: true

require 'spec_helper'
require 'fileutils'
require 'json'
require 'tmpdir'
require 'woods'
require 'woods/mcp/server'

# Auto-reload + graceful no-index boot for the Index Server.
#
# The server used to load tmp/woods/ once at boot: after a re-extraction,
# clients had to call `reload` manually or restart the MCP connection, and
# a woods-mcp launched before the first extraction (editor/agent configs
# start MCP servers at session start) hard-failed. Now every tools/call
# stats manifest.json and reloads on change, and a server booted over a
# missing/empty index directory serves guidance instead of erroring —
# picking the index up automatically once it appears.
RSpec.describe 'Woods::MCP::Server index auto-refresh' do
  let(:fixture_dir) { File.expand_path('../fixtures/woods', __dir__) }

  # Drive tools/call through the real JSON-RPC entry point so the dispatch
  # hook (a prepend on the server instance) is exercised as in production.
  def tools_call(server, name, arguments: {})
    request = JSON.generate(
      jsonrpc: '2.0', id: 1, method: 'tools/call',
      params: { name: name, arguments: arguments }
    )
    JSON.parse(server.handle_json(request))
  end

  def result_text(response)
    response.dig('result', 'content', 0, 'text')
  end

  around do |example|
    Dir.mktmpdir('woods_auto_refresh') do |dir|
      @dir = dir
      example.run
    end
  end

  def copy_fixture_index!(mtime: nil)
    FileUtils.cp_r(File.join(fixture_dir, '.'), @dir)
    FileUtils.touch(File.join(@dir, 'manifest.json'), mtime: mtime) if mtime
  end

  def rewrite_manifest!(mtime:, **overrides)
    path = File.join(@dir, 'manifest.json')
    manifest = JSON.parse(File.read(path)).merge(overrides.transform_keys(&:to_s))
    File.write(path, JSON.generate(manifest))
    FileUtils.touch(path, mtime: mtime)
  end

  describe 'auto-reload when the index changes on disk' do
    it 'serves the updated index on the next tool call without a manual reload' do
      copy_fixture_index!(mtime: Time.now - 120)
      server = Woods::MCP::Server.build(index_dir: @dir, warmup: false)

      before = JSON.parse(result_text(tools_call(server, 'woods_status')))
      expect(before.dig('index', 'total_units')).to eq(9)

      rewrite_manifest!(mtime: Time.now + 60, total_units: 42)

      after = JSON.parse(result_text(tools_call(server, 'woods_status')))
      expect(after.dig('index', 'total_units')).to eq(42)
    end

    it 'does not reload when the manifest is unchanged' do
      copy_fixture_index!(mtime: Time.now - 120)
      server = Woods::MCP::Server.build(index_dir: @dir, warmup: false)
      reader = server.instance_variable_get(:@woods_index_reader)

      tools_call(server, 'structure')
      graph = reader.dependency_graph

      tools_call(server, 'structure')
      expect(reader.dependency_graph).to equal(graph)
    end
  end

  describe 'graceful boot when the index directory is missing or empty' do
    it 'builds a server over an empty directory' do
      expect { Woods::MCP::Server.build(index_dir: @dir, warmup: false) }.not_to raise_error
    end

    it 'builds a server over a non-existent directory' do
      missing = File.join(@dir, 'never/created')
      expect { Woods::MCP::Server.build(index_dir: missing, warmup: false) }.not_to raise_error
    end

    it 'answers index-backed tools with extraction guidance instead of an error dump' do
      server = Woods::MCP::Server.build(index_dir: @dir, warmup: false)

      response = tools_call(server, 'lookup', arguments: { identifier: 'Post' })

      expect(response.dig('result', 'isError')).to be true
      text = result_text(response)
      expect(text).to include('woods:extract')
      expect(response.dig('result', '_meta', 'error_code')).to eq('no_index')
    end

    it 'reports the missing index through woods_status with guidance' do
      server = Woods::MCP::Server.build(index_dir: @dir, warmup: false)

      status = JSON.parse(result_text(tools_call(server, 'woods_status')))

      expect(status['ready']).to be false
      expect(status.dig('index', 'present')).to be false
      expect(status.dig('index', 'guidance')).to include('woods:extract')
    end

    it 'responds to reload without raising when no index exists' do
      server = Woods::MCP::Server.build(index_dir: @dir, warmup: false)

      response = tools_call(server, 'reload')

      expect(response).to have_key('result')
      payload = JSON.parse(result_text(response))
      expect(payload['reloaded']).to be false
      expect(payload['guidance']).to include('woods:extract')
    end

    it 'picks the index up automatically once an extraction writes it' do
      server = Woods::MCP::Server.build(index_dir: @dir, warmup: false)
      expect(tools_call(server, 'lookup', arguments: { identifier: 'Post' })
        .dig('result', 'isError')).to be true

      copy_fixture_index!

      response = tools_call(server, 'lookup', arguments: { identifier: 'Post' })
      expect(response.dig('result', 'isError')).to be_falsey
      expect(result_text(response)).to include('Post')
    end
  end
end
