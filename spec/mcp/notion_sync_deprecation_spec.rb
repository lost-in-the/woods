# frozen_string_literal: true

require 'spec_helper'
require 'woods'
require 'woods/mcp/server'
require 'woods/deprecation'
require 'woods/notion/exporter'

RSpec.describe 'notion_sync MCP tool deprecation' do
  let(:fixture_dir) { File.expand_path('../fixtures/woods', __dir__) }
  let(:server) { Woods::MCP::Server.build(index_dir: fixture_dir) }
  let(:tool) { server.instance_variable_get(:@tools).fetch('notion_sync') }

  before do
    Woods::Deprecation.reset!
    Woods.configuration = Woods::Configuration.new.tap do |config|
      config.notion_api_token = 'secret_token_fixture'
      config.notion_database_ids = { data_models: 'db-uuid' }
    end
    stats = { data_models: 1, columns: 1, skipped: 0, errors: [] }
    exporter = instance_double(Woods::Notion::Exporter, sync_all: stats)
    allow(Woods::Notion::Exporter).to receive(:new).and_return(exporter)
  end

  after { Woods.configuration = nil }

  it 'still syncs and warns on stderr, pointing at the Markdown export' do
    response = nil
    expect { response = tool.call(server_context: {}) }
      .to output(/DEPRECATED.*notion_sync.*woods:markdown/).to_stderr
    expect(response.error?).to be_falsey
  end

  it 'warns once per process' do
    tool.call(server_context: {})
    expect { tool.call(server_context: {}) }.not_to output.to_stderr
  end

  it 'marks the tool description as deprecated' do
    expect(tool.description).to start_with('Deprecated')
  end
end
