# frozen_string_literal: true

require 'spec_helper'
require 'fileutils'
require 'open3'
require 'tmpdir'
require 'woods'
require 'woods/mcp/server'
require 'woods/mcp/config_resolver'
require 'woods/index_artifact'

RSpec.describe 'Index MCP startup guidance and path selection' do
  let(:root) { File.expand_path('../..', __dir__) }
  let(:fixture) { File.join(root, 'spec/fixtures/woods') }
  let(:request) do
    initialize_request = JSON.generate(jsonrpc: '2.0', id: 1, method: 'initialize',
                                       params: { protocolVersion: '2025-06-18', capabilities: {},
                                                 clientInfo: { name: 'index-path-spec', version: '1' } })
    "#{initialize_request}\n"
  end

  around do |example|
    Dir.mktmpdir('woods-index-path') do |directory|
      @directory = directory
      @legacy = File.join(directory, 'legacy')
      @atomic = File.join(directory, 'atomic')
      @cwd = File.join(directory, 'unrelated')
      FileUtils.cp_r(fixture, @legacy)
      payload = File.join(@atomic, 'payloads/gen-1')
      FileUtils.mkdir_p(File.dirname(payload))
      FileUtils.cp_r(fixture, payload)
      File.write(File.join(@atomic, 'generation.json'),
                 JSON.generate(number: 1, token: 'published', payload: 'payloads/gen-1'))
      FileUtils.mkdir_p(@cwd)
      example.run
    end
  end

  def launch(executable, *arguments, env: {}, cwd: @cwd)
    settings = { 'BUNDLE_GEMFILE' => File.join(root, 'Gemfile'), 'WOODS_DIR' => nil, 'WOODS_OUTPUT' => nil,
                 'WOODS_RETRIEVAL_MODE' => 'lexical', 'WOODS_REQUIRE_INDEX' => nil, 'WOODS_SNAPSHOTS' => nil,
                 'MCP_PROTOCOL_VERSION' => nil, 'WOODS_NO_UPDATE_CHECK' => '1', 'OPENAI_API_KEY' => nil }
    output, errors, status = Open3.capture3(settings.merge(env), 'bundle', 'exec', 'ruby',
                                            File.join(root, 'exe', executable), *arguments,
                                            stdin_data: request, chdir: cwd)
    [output, errors.force_encoding(Encoding::UTF_8).scrub, status]
  end

  %w[woods-mcp woods-mcp-start].each do |executable|
    context executable do
      it 'boots an atomic index via WOODS_OUTPUT from an unrelated working directory' do
        output, errors, status = launch(executable, env: { 'WOODS_OUTPUT' => @atomic })
        expect(status).to be_success, errors
        expect(JSON.parse(output).dig('result', 'serverInfo', 'name')).to eq('woods')
      end

      it 'prefers WOODS_DIR over WOODS_OUTPUT and preserves legacy flat indexes' do
        output, errors, status = launch(executable,
                                        env: { 'WOODS_DIR' => @legacy, 'WOODS_OUTPUT' => '/missing/output' })
        expect(status).to be_success, errors
        expect(JSON.parse(output).dig('result', 'serverInfo', 'name')).to eq('woods')
      end

      it 'prefers an explicit index over both environment paths' do
        output, errors, status = launch(executable, @atomic,
                                        env: { 'WOODS_DIR' => '/missing/dir', 'WOODS_OUTPUT' => '/missing/output' })
        expect(status).to be_success, errors
        expect(JSON.parse(output).dig('result', 'serverInfo', 'name')).to eq('woods')
      end

      it 'does not fall through a bad explicit path to a valid environment path' do
        output, errors, status = launch(executable, 'missing',
                                        env: { 'WOODS_DIR' => @legacy, 'WOODS_OUTPUT' => @atomic })
        expect(status.exitstatus).to eq(1)
        expect(output).to be_empty
        expect(errors).to include(File.join(@cwd, 'missing'), 'existing index', 'WOODS_DIR', 'WOODS_OUTPUT')
      end

      it 'preserves the empty WOODS_DIR override instead of falling through to WOODS_OUTPUT' do
        output, _errors, status = launch(executable, env: { 'WOODS_DIR' => '', 'WOODS_OUTPUT' => @atomic })
        expect(status.exitstatus).to eq(1)
        expect(output).to be_empty
      end

      it 'uses a layout-neutral headline when the selected directory has no published index' do
        output, errors, status = launch(executable, @cwd)
        expect(status.exitstatus).to eq(1)
        expect(output).to be_empty
        expect(errors.lines.first).to eq("Error: Could not resolve a published Woods index in: #{@cwd}\n")
        expect(errors).to include('generation.json', 'legacy flat manifest.json', 'existing index')
      end

      ['{broken', '[]', '{"number":1,"payload":42}', '{"number":1,"payload":"../legacy"}'].each do |marker|
        it "rejects invalid generation #{marker.inspect} with the selected path and remedy" do
          File.write(File.join(@atomic, 'generation.json'), marker)
          output, errors, status = launch(executable, @atomic)
          expect(status.exitstatus).to eq(1)
          expect(output).to be_empty
          expect(errors).to include(@atomic, 'generation.json', 'manifest.json', 'existing index')
          expect(errors).not_to include('NoMethodError', 'TypeError', 'from ')
        end
      end

      it 'rejects a generation payload symlink that escapes the selected index' do
        File.symlink(@legacy, File.join(@atomic, 'escape'))
        File.write(File.join(@atomic, 'generation.json'), JSON.generate(number: 1, payload: 'escape'))
        output, errors, status = launch(executable, @atomic)
        expect(status.exitstatus).to eq(1)
        expect(output).to be_empty
        expect(errors).to include(@atomic, 'generation.json', 'existing index')
      end
    end
  end

  it 'keeps the direct executable current-directory default' do
    output, errors, status = launch('woods-mcp', cwd: @legacy)
    expect(status).to be_success, errors
    expect(JSON.parse(output).dig('result', 'serverInfo', 'name')).to eq('woods')
  end

  it 'keeps the launcher no-path error even when the current directory is an index' do
    output, errors, status = launch('woods-mcp-start', cwd: @legacy)
    expect(status.exitstatus).to eq(1)
    expect(output).to be_empty
    expect(errors).to include('No index directory specified', 'Usage:')
  end

  it 'uses the shared output fallback and generation-aware diagnostic in HTTP startup' do
    selected = File.join(@directory, 'http-selected-empty-index')
    FileUtils.mkdir_p(selected)
    output, errors, status = launch('woods-mcp-http', env: { 'WOODS_OUTPUT' => selected })
    expect(status.exitstatus).to eq(1)
    expect(output).to be_empty
    expect(errors.lines.first).to eq("Error: Could not resolve a published Woods index in: #{selected}\n")
    expect(errors).to include(selected, 'generation.json', 'manifest.json', 'existing index')
  end

  it 'offers explicit lexical mode in the no-retriever error without changing typed metadata' do
    server = Woods::MCP::Server.build(index_dir: @legacy)
    call = { jsonrpc: '2.0', id: 2, method: 'tools/call',
             params: { name: 'codebase_retrieve', arguments: { query: 'billing' } } }
    response = JSON.parse(server.handle_json(JSON.generate(call)))
    result = response.fetch('result')
    expect(result['isError']).to be(true)
    expect(result.fetch('_meta')).to include('error_code' => 'not_configured', 'config_key' => 'embedding_provider')
    expect(result.dig('content', 0, 'text')).to include('WOODS_RETRIEVAL_MODE=lexical', 'restart', 'no embeddings',
                                                        'OPENAI_API_KEY', 'Ollama', '`search`',
                                                        'docs/RETRIEVAL_GUIDE.md#embedding-free-lexical-retrieval')
  end

  it 'offers lexical opt-in on stderr while leaving the default provider unconfigured' do
    config = Woods::Configuration.new
    expect do
      Woods::MCP::ConfigResolver.resolve(config, artifact: Woods::IndexArtifact.new(@legacy),
                                                 env: {}, ollama_probe: -> { false })
    end.to output(/WOODS_RETRIEVAL_MODE=lexical.*restart/).to_stderr
    expect(config.retrieval_mode).to eq(:semantic)
    expect(config.embedding_provider).to be_nil
  end
end
