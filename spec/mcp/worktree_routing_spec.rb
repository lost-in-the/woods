# frozen_string_literal: true

require 'spec_helper'
require 'digest'
require 'fileutils'
require 'json'
require 'open3'
require 'tmpdir'
require 'woods'
require 'woods/mcp/server'
require_relative '../support/quiet_git'

# One Index MCP server, several worktrees of one repository. A subagent that
# edits another worktree names it with `root`; everything else keeps serving
# the index the server was launched with.
RSpec.describe 'Index MCP per-call worktree root' do
  let(:base) { File.realpath(Dir.mktmpdir('woods-worktree-routing')) }
  let(:main_root) { File.join(base, 'main') }
  let(:feature_root) { File.join(base, 'feature') }
  let(:bare_root) { File.join(base, 'unindexed') }
  let(:outside_root) { File.join(base, 'outside') }
  let(:main_index) { File.join(main_root, 'tmp', 'woods') }
  let(:feature_index) { File.join(feature_root, 'tmp', 'woods') }
  let(:server) { Woods::MCP::Server.build(index_dir: main_index, response_format: :json, warmup: false) }

  after { FileUtils.rm_rf(base) }

  before do
    git(base, 'init', '-q', '-b', 'main', main_root)
    QuietGit.configure(main_root)
    File.write(File.join(main_root, 'README.md'), "hi\n")
    git(main_root, 'add', 'README.md')
    git(main_root, '-c', 'user.name=Spec', '-c', 'user.email=spec@example.com', '-c', 'commit.gpgsign=false',
        'commit', '-q', '-m', 'init')
    git(main_root, 'worktree', 'add', '-q', '-b', 'feature', feature_root)
    git(main_root, 'worktree', 'add', '-q', '-b', 'unindexed', bare_root)
    FileUtils.mkdir_p(outside_root)
    FileUtils.mkdir_p(File.join(bare_root, 'tmp', 'woods'))

    publish(main_index, 1, branch: 'main', units: { 'Post' => "class Post\nend\n" })
    feature_units = { 'Post' => "class Post\n  def only_in_feature; end\nend\n", 'Widget' => "class Widget\nend\n" }
    publish(feature_index, 4, branch: 'feature', units: feature_units)
  end

  def git(dir, *args)
    output, status = Open3.capture2e('git', '-C', dir, *args)
    raise "git #{args.join(' ')} failed: #{output}" unless status.success?

    output
  end

  # Publishes a payload generation holding one `models` family.
  def publish(index_dir, number, branch:, units:)
    payload = File.join(index_dir, 'payloads', "gen-#{number}")
    FileUtils.mkdir_p(File.join(payload, 'models'))
    write_json(File.join(payload, 'manifest.json'),
               'extracted_at' => '2026-01-15T12:00:00Z', 'git_sha' => "sha-#{branch}", 'git_branch' => branch,
               'woods_version' => Woods::VERSION, 'counts' => { 'models' => units.size }, 'total_units' => units.size)
    write_json(File.join(payload, 'dependency_graph.json'), 'nodes' => {}, 'edges' => {})
    entries = units.map { |identifier, source| write_unit(payload, identifier, source) }
    write_json(File.join(payload, 'models', '_index.json'), entries)
    write_json(File.join(index_dir, 'generation.json'),
               'number' => number, 'token' => "tok#{number}", 'updated_at' => '2026-01-15T12:00:00Z',
               'reason' => 'full', 'payload' => "payloads/gen-#{number}")
  end

  def write_unit(payload, identifier, source)
    file_path = "app/models/#{identifier.downcase}.rb"
    filename = "#{identifier}_#{Digest::SHA256.hexdigest(identifier)[0, 8]}.json"
    write_json(File.join(payload, 'models', filename),
               'type' => 'model', 'identifier' => identifier, 'file_path' => file_path, 'source_code' => source,
               'metadata' => {}, 'dependencies' => [], 'dependents' => [])
    { 'identifier' => identifier, 'file_path' => file_path }
  end

  def write_json(path, data)
    File.write(path, JSON.generate(data))
  end

  def rpc(name, arguments, on: server)
    raw = on.handle_json(JSON.generate(jsonrpc: '2.0', id: 1, method: 'tools/call',
                                       params: { name: name, arguments: arguments, '_meta' => meta }))
    JSON.parse(raw)
  end

  def meta
    { 'io.modelcontextprotocol/protocolVersion' => '2026-07-28',
      'io.modelcontextprotocol/clientInfo' => { 'name' => 'worktree-routing-spec', 'version' => '1.0' },
      'io.modelcontextprotocol/clientCapabilities' => {} }
  end

  def result_text(response)
    response.dig('result', 'content', 0, 'text')
  end

  it 'answers from the named worktree when root is passed, and from the launch index otherwise' do
    default = JSON.parse(result_text(rpc('lookup', { 'identifier' => 'Post' })))
    routed = JSON.parse(result_text(rpc('lookup', { 'identifier' => 'Post', 'root' => feature_root })))

    expect(default['source_code']).not_to include('only_in_feature')
    expect(routed['source_code']).to include('only_in_feature')
  end

  it 'serves a unit that exists in only one worktree' do
    expect(rpc('lookup', { 'identifier' => 'Widget' }).dig('result', 'isError')).to be(true)
    expect(rpc('lookup', { 'identifier' => 'Widget', 'root' => feature_root }).dig('result', 'isError')).to be_falsey
  end

  it 'pins each answer to the generation of the root it names' do
    main_status = JSON.parse(result_text(rpc('woods_status', {})))
    feature_status = JSON.parse(result_text(rpc('woods_status', { 'root' => feature_root })))

    expect(main_status.dig('index', 'generation')).to eq(1)
    expect(feature_status.dig('index', 'generation')).to eq(4)
    expect(feature_status.dig('index', 'git_branch')).to eq('feature')
    expect(feature_status.dig('server', 'index_dir')).to eq(feature_index)
  end

  it 'accepts a root with a trailing slash or through a symlink' do
    link = File.join(base, 'feature-link')
    File.symlink(feature_root, link)

    expect(rpc('lookup', { 'identifier' => 'Widget', 'root' => "#{feature_root}/" }).dig('result',
                                                                                         'isError')).to be_falsey
    expect(rpc('lookup', { 'identifier' => 'Widget', 'root' => link }).dig('result', 'isError')).to be_falsey
  end

  it 'routes other read tools too' do
    search = JSON.parse(result_text(rpc('search', { 'query' => 'Widget', 'root' => feature_root })))

    expect(JSON.generate(search)).to include('Widget')
  end

  it 'refuses a path outside the repository worktrees with a typed error naming root' do
    response = rpc('lookup', { 'identifier' => 'Post', 'root' => outside_root })

    expect(response.dig('result', 'isError')).to be(true)
    meta = response.dig('result', '_meta')
    expect(meta).to include('error_code' => 'invalid_params', 'argument' => 'root', 'tool' => 'lookup')
    expect(meta['accepted_roots']).to contain_exactly(main_root, feature_root, bare_root)
    expect(result_text(response)).to include('root')
  end

  it 'refuses a relative or non-string root' do
    relative = rpc('lookup', { 'identifier' => 'Post', 'root' => 'feature' })
    numeric = rpc('lookup', { 'identifier' => 'Post', 'root' => 3 })

    expect(relative.dig('result', '_meta')).to include('error_code' => 'invalid_params', 'argument' => 'root')
    expect(numeric.dig('result', '_meta')).to include('argument' => 'root')
  end

  it 'refuses a worktree that has no published index, naming root' do
    response = rpc('lookup', { 'identifier' => 'Post', 'root' => bare_root })

    expect(response.dig('result', 'isError')).to be(true)
    expect(response.dig('result', '_meta')).to include('argument' => 'root', 'error_code' => 'not_found')
  end

  it 'picks up a worktree added after the server booted' do
    late_root = File.join(base, 'late')
    git(main_root, 'worktree', 'add', '-q', '-b', 'late', late_root)
    publish(File.join(late_root, 'tmp', 'woods'), 2, branch: 'late', units: { 'Late' => "class Late\nend\n" })

    expect(rpc('lookup', { 'identifier' => 'Late', 'root' => late_root }).dig('result', 'isError')).to be_falsey
  end

  it 'refuses every root when the served index belongs to no repository' do
    elsewhere = File.join(base, 'elsewhere-index')
    FileUtils.cp_r(main_index, elsewhere)
    built = Woods::MCP::Server.build(index_dir: elsewhere, response_format: :json, warmup: false)
    response = rpc('lookup', { 'identifier' => 'Post', 'root' => feature_root }, on: built)

    expect(response.dig('result', '_meta')).to include('argument' => 'root', 'error_code' => 'invalid_params')
    expect(response.dig('result', '_meta', 'accepted_roots')).to eq([])
  end

  it 'lists each worktree in woods_status with generation, branch, sha and watcher' do
    worktrees = JSON.parse(result_text(rpc('woods_status', {})))['worktrees']
    by_root = worktrees.to_h { |entry| [entry['root'], entry] }

    expect(by_root.keys).to contain_exactly(main_root, feature_root, bare_root)
    expect(by_root[main_root]).to include('default' => true, 'state' => 'indexed', 'generation' => 1,
                                          'git_branch' => 'main', 'git_sha' => 'sha-main', 'index_dir' => main_index)
    expect(by_root[feature_root]).to include('default' => false, 'state' => 'indexed', 'generation' => 4,
                                             'git_branch' => 'feature')
    expect(by_root[feature_root]['watch']).to include('state' => 'absent')
    expect(by_root[bare_root]).to include('state' => 'unextracted', 'generation' => nil)
  end

  it 'adds root to the schema of the read tools and nothing else' do
    tools = server.tools
    with_root = tools.select { |_name, tool| tool.input_schema_value.to_h.dig(:properties, :root) }.keys

    expect(with_root).to contain_exactly(*Woods::MCP::WorktreeRouting::ROOT_TOOLS)
    expect(with_root).to include('lookup', 'search', 'woods_status')
    expect(with_root).not_to include('reload', 'codebase_retrieve')
    expect(server.tools.keys).to eq(server.tools.keys.sort)
  end

  it 'leaves a call without root untouched by routing state' do
    first = result_text(rpc('lookup', { 'identifier' => 'Post' }))
    rpc('lookup', { 'identifier' => 'Post', 'root' => feature_root })
    second = result_text(rpc('lookup', { 'identifier' => 'Post' }))

    expect(second).to eq(first)
    expect(Thread.current[Woods::MCP::WorktreeRouting::THREAD_KEY]).to be_nil
  end
end
