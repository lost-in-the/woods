# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'woods/source_inputs/session'
require 'woods/mcp/index_reader'
require 'woods/mcp/server'

RSpec.describe 'Source freshness on a served generation' do
  around do |example|
    Dir.mktmpdir('woods-source-reader') do |root|
      @root = root
      @output = File.join(root, 'index')
      @source = File.join(root, 'app/services/pay.rb')
      FileUtils.mkdir_p(File.dirname(@source))
      @key = Woods::SourceInputs::PrivateKey.new(output_dir: @output, create: true)
      example.run
    end
  end

  def publish(bytes) # rubocop:disable Metrics/AbcSize -- publishes a complete independent generation fixture
    File.write(@source, bytes)
    capture = Woods::SourceInputs::Scanner.new(root: @root, output_dir: @output, key: @key).call
    scopes = capture.fetch('scope_paths').transform_values do |paths|
      paths.to_h { |path| [path, capture.fetch('files').fetch(path)] }
    end
    generation = Woods::Generation.new(output_dir: @output)
    number = generation.current.number + 1
    payload = "payloads/gen-#{number}"
    dir = File.join(@output, payload)
    FileUtils.mkdir_p(dir)
    manifest = Woods::SourceInputs::Manifest.build(snapshot: capture, scopes: scopes, boot_verified: true,
                                                   generation: number)
    File.write(File.join(dir, 'source_inputs.json'), JSON.generate(manifest.data))
    File.write(File.join(dir, 'manifest.json'), JSON.generate(counts: {}, extracted_at: Time.now.utc.iso8601))
    generation.bump!(reason: 'full', payload: payload)
  end

  it 'checks the held generation rather than borrowing a newer generation baseline' do
    publish('before')
    reader = Woods::MCP::IndexReader.new(@output)
    reader.with_pinned_generation do
      expect(reader.source_freshness).to include('state' => 'current', 'generation' => 1)
      publish('after')
      result = Woods::MCP::Server.build_status(reader: reader, retriever: nil, index_dir: @output, source_check: 'deep')
      expect(result[:index][:source_freshness]).to include('state' => 'drifted', 'generation' => 1, 'check' => 'deep')
      expect(result[:index][:source_freshness]['changes']['changed']).to eq(['app/services/pay.rb'])
    end
    expect(reader.source_freshness).to include('state' => 'current', 'generation' => 2)
  end

  it 'advertises quick/deep checks and carries the requested mode through the callable tool' do
    publish('before')
    server = Woods::MCP::Server.build(index_dir: @output, response_format: :json, warmup: false)
    tool = server.instance_variable_get(:@tools).fetch('woods_status')
    schema = JSON.parse(JSON.generate(tool.input_schema.to_h))
    expect(schema.dig('properties', 'source_check', 'enum')).to eq(%w[quick deep])
    response = tool.call(source_check: 'deep', server_context: {})
    result = JSON.parse(response.content.first.fetch(:text))
    expect(result.dig('index', 'source_freshness')).to include('state' => 'current', 'check' => 'deep')
  end

  it 'never caches source evidence across edits with an unchanged index generation' do
    publish('before')
    reader = Woods::MCP::IndexReader.new(@output)
    expect(reader.source_freshness['state']).to eq('current')
    File.write(@source, 'after')
    expect(reader.source_freshness).to include('state' => 'drifted', 'generation' => 1)
  end
end
