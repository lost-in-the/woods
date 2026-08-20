# frozen_string_literal: true

require 'spec_helper'
require 'fileutils'
require 'json'
require 'tmpdir'
require 'woods/mcp/index_reader'
require 'woods/mcp/server'

RSpec.describe 'Index MCP exclusive reload contract' do
  let(:index_dir) { Dir.mktmpdir('woods-mcp-exclusive-reload') }
  let(:manifest_path) { File.join(index_dir, 'manifest.json') }
  let(:reader) { Woods::MCP::IndexReader.new(index_dir, auto_refresh: false) }
  let(:reloader_entered) { Queue.new }
  let(:finish_reloader) { Queue.new }
  let(:retriever_reloader) do
    Class.new do
      def initialize(entered, finish)
        @entered = entered
        @finish = finish
      end

      def call
        @entered << true
        @finish.pop
        { vectors: 22, metadata: 22, graph: 1 }
      end
    end.new(reloader_entered, finish_reloader)
  end
  let(:server) do
    allow(Woods::MCP::IndexReader).to receive(:new).with(index_dir).and_return(reader)
    Woods::MCP::Server.build(
      index_dir: index_dir,
      response_format: :json,
      warmup: false,
      retriever_reloader: retriever_reloader
    )
  end

  before { write_manifest(total_units: 1) }

  after { FileUtils.rm_rf(index_dir) }

  it 'waits for active pins, blocks later readers, and returns one post-reload snapshot' do
    server
    expect(reader).to respond_to(:with_exclusive_reload)
    expect(reader.manifest['total_units']).to eq(1)

    active_entered = Queue.new
    release_active = Queue.new
    active = Thread.new do
      reader.with_pinned_generation do
        first = reader.manifest['total_units']
        active_entered << true
        release_active.pop
        [first, reader.manifest['total_units']]
      end
    end
    active_entered.pop
    write_manifest(total_units: 2)

    reload = Thread.new { dispatch_reload }
    poll_until(timeout: 1) { reader.instance_variable_get(:@exclusive_waiters).to_i.positive? }

    later_entered = Queue.new
    later = Thread.new do
      reader.with_pinned_generation do
        later_entered << true
        reader.manifest['total_units']
      end
    end
    sleep 0.02
    expect(reloader_entered).to be_empty
    expect(later_entered).to be_empty

    release_active << true
    reloader_entered.pop
    expect(later_entered).to be_empty

    finish_reloader << true
    response = reload.value

    expect(response.dig('structuredContent', 'data')).to eq(
      'reloaded' => true,
      'extracted_at' => '2026-08-20T00:00:00Z',
      'total_units' => 2,
      'counts' => { 'models' => 2 },
      'retriever' => { 'vectors' => 22, 'metadata' => 22, 'graph' => 1 }
    )
    expect(active.value).to eq([1, 1])
    expect(later.value).to eq(2)
  ensure
    release_active << true if active&.alive?
    finish_reloader << true if reload&.alive?
    [active, reload, later].compact.each { |thread| thread.join(1) }
  end

  def write_manifest(total_units:)
    File.write(
      manifest_path,
      JSON.generate(
        'extracted_at' => '2026-08-20T00:00:00Z',
        'total_units' => total_units,
        'counts' => { 'models' => total_units }
      )
    )
  end

  def dispatch_reload
    request = {
      jsonrpc: '2.0',
      id: 1,
      method: 'tools/call',
      params: {
        name: 'reload',
        arguments: {},
        _meta: {
          'io.modelcontextprotocol/protocolVersion' => '2026-07-28',
          'io.modelcontextprotocol/clientInfo' => { 'name' => 'reload-spec', 'version' => '1.0' },
          'io.modelcontextprotocol/clientCapabilities' => {}
        }
      }
    }
    JSON.parse(server.handle_json(JSON.generate(request))).fetch('result')
  end
end
