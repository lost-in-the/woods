# frozen_string_literal: true

require 'spec_helper'
require 'fileutils'
require 'json'
require 'open3'
require 'rbconfig'
require 'tmpdir'
require 'woods'
require 'woods/mcp/server'
require 'woods/mcp/served_identity'

# Several checkouts of one repository, each with its own published index.
RSpec.describe 'Served index identity' do
  let(:fixture_dir) { File.expand_path('../fixtures/woods', __dir__) }
  let(:writer_revision) { 'a' * 40 }
  let(:released) { instance_double(Woods::BuildIdentity, version: Woods::VERSION, revision: nil, dirty: nil) }

  around do |example|
    Dir.mktmpdir('woods-two-checkouts') do |directory|
      @base = File.realpath(directory)
      example.run
    end
  end

  before { Woods.configuration = Woods::Configuration.new }

  # A checkout (a `.git` directory with a HEAD file is enough: identity reads
  # files, never runs git) with its own published index at tmp/woods.
  def checkout(name, branch: 'main', generation: 1, manifest: {})
    root = File.join(@base, name)
    FileUtils.mkdir_p(File.join(root, '.git'))
    File.write(File.join(root, '.git', 'HEAD'), branch ? "ref: refs/heads/#{branch}\n" : "#{'c' * 40}\n")
    index = File.join(root, 'tmp', 'woods')
    payload = File.join(index, 'payloads', "gen-#{generation}")
    FileUtils.mkdir_p(File.dirname(payload))
    FileUtils.cp_r(fixture_dir, payload)
    recorded = JSON.parse(File.read(File.join(payload, 'manifest.json')))
                   .merge('woods_version' => Woods::VERSION, 'root' => root, 'git_branch' => branch || 'HEAD')
                   .merge(manifest)
    File.write(File.join(payload, 'manifest.json'), JSON.generate(recorded))
    File.write(File.join(index, 'generation.json'),
               JSON.generate(number: generation, token: "t#{generation}", updated_at: '2026-11-01T10:00:00Z',
                             reason: 'extract', payload: "payloads/gen-#{generation}"))
    root
  end

  def index_of(root)
    File.join(root, 'tmp', 'woods')
  end

  def build_server(index_dir)
    Woods::MCP::Server.build(index_dir: index_dir, warmup: false)
  end

  def rpc(server, method, params)
    request = { jsonrpc: '2.0', id: 1, method: method, params: params }
    JSON.parse(server.handle_json(JSON.generate(request))).fetch('result')
  end

  def instructions(server)
    rpc(server, 'initialize', protocolVersion: '2025-06-18', capabilities: {},
                              clientInfo: { name: 'identity-spec', version: '1' }).fetch('instructions')
  end

  def call(server, name, arguments = {})
    rpc(server, 'tools/call', name: name, arguments: arguments)
  end

  def status(server)
    JSON.parse(call(server, 'woods_status').dig('content', 0, 'text'))
  end

  describe 'two checkouts with their own indexes' do
    it 'each report their own root, branch and generation' do
      alpha = checkout('checkout-alpha', branch: 'main', generation: 3)
      beta = checkout('checkout-beta', branch: 'feature-x', generation: 7)

      [[alpha, 'main', 3], [beta, 'feature-x', 7]].each do |root, branch, generation|
        identity = Dir.chdir(root) { status(build_server(index_of(root))).fetch('identity') }

        expect(identity).to include('root' => root, 'root_name' => File.basename(root), 'branch' => branch,
                                    'generation' => generation, 'generation_updated_at' => '2026-11-01T10:00:00Z',
                                    'woods_version' => Woods::VERSION, 'client_matches' => true,
                                    'client_root' => root, 'branch_matches' => true)
      end
    end

    it 'leads initialize instructions with the checkout, branch, generation and writer' do
      alpha = checkout('checkout-alpha', branch: 'main', generation: 3)

      text = Dir.chdir(alpha) { instructions(build_server(index_of(alpha))) }

      expect(text.lines.first).to eq(
        "Serving the index of checkout-alpha (#{alpha}), branch main, generation 3, " \
        "updated 2026-11-01T10:00:00Z, written by Woods #{Woods::VERSION}.\n"
      )
      expect(text).to include('Start with woods_status')
      expect(text).not_to include('WARNING')
      expect(text.bytesize).to be <= 2048
    end

    it 'leads woods_status with identity and client_matches' do
      alpha = checkout('checkout-alpha')
      beta = checkout('checkout-beta')

      report = Dir.chdir(beta) { status(build_server(index_of(alpha))) }

      expect(report.keys.first).to eq('identity')
      expect(report.fetch('identity')).to include('root' => alpha, 'client_root' => beta, 'client_matches' => false,
                                                  'client_match_reason' => 'different_checkout')
    end

    it 'warns in the instructions when served to another checkout' do
      alpha = checkout('checkout-alpha')
      beta = checkout('checkout-beta')

      text = Dir.chdir(beta) { instructions(build_server(index_of(alpha))) }

      expect(text.lines[1]).to start_with("WARNING: This index describes #{alpha}, not the launch checkout #{beta}")
    end

    it 'matches an application in a subdirectory of its checkout, and not a worktree nested inside it' do
      alpha = checkout('checkout-alpha')
      application = File.join(alpha, 'apps', 'web')
      FileUtils.mkdir_p(application)
      nested = checkout('checkout-alpha/worktrees/nested')

      inside = Woods::MCP::ServedIdentity.read(index_of(alpha), cwd: alpha, manifest: { 'root' => application })
      foreign = Woods::MCP::ServedIdentity.read(index_of(nested), cwd: alpha)

      expect(inside.client_matches).to be(true)
      expect(inside.root_name).to eq('checkout-alpha')
      expect(foreign.client_matches).to be(false)
    end

    it "falls back to the index's own checkout for a root written elsewhere, as inside a container" do
      alpha = checkout('checkout-alpha', manifest: { 'root' => '/nonexistent-container-root/app' })
      beta = checkout('checkout-beta')

      same = Woods::MCP::ServedIdentity.read(index_of(alpha), cwd: alpha)
      other = Woods::MCP::ServedIdentity.read(index_of(alpha), cwd: beta)

      expect(same.client_matches).to be(true)
      expect(same.to_h).to include(root: '/nonexistent-container-root/app', repository_root: alpha,
                                   root_source: 'index_location')
      expect(other.client_matches).to be(false)
    end

    it 'cannot tell when neither the recorded root nor the index is in a reachable checkout' do
      alpha = checkout('checkout-alpha')
      detached_index = File.join(@base, 'indexes', 'copy')
      FileUtils.mkdir_p(File.dirname(detached_index))
      FileUtils.cp_r(index_of(alpha), detached_index)
      gone = { 'root' => '/nonexistent-container-root/app' }

      unreachable = Woods::MCP::ServedIdentity.read(detached_index, cwd: alpha, manifest: gone)
      unrecorded = Woods::MCP::ServedIdentity.read(detached_index, cwd: alpha, manifest: {})

      expect([unreachable.client_matches, unreachable.match_reason]).to eq([nil, 'recorded_root_unreachable'])
      expect([unrecorded.client_matches, unrecorded.match_reason]).to eq([nil, 'root_not_recorded'])
      expect(unreachable.warnings).to be_empty
    end

    it 'identifies an index written before roots were recorded by the checkout that holds it' do
      alpha = checkout('checkout-alpha', manifest: { 'root' => nil })

      identity = Woods::MCP::ServedIdentity.read(index_of(alpha), cwd: alpha)

      expect(identity.root_name).to eq('checkout-alpha')
      expect(identity.client_matches).to be(true)
    end

    it 'cannot tell when the launcher is outside any checkout' do
      alpha = checkout('checkout-alpha')
      outside = File.join(@base, 'plain-directory')
      FileUtils.mkdir_p(outside)

      expect(Woods::MCP::ServedIdentity.read(index_of(alpha), cwd: outside).match_reason)
        .to eq('client_outside_checkout')
    end

    it 'reads a linked worktree branch through its gitdir pointer, and a detached HEAD as no branch' do
      alpha = checkout('checkout-alpha')
      linked = File.join(@base, 'checkout-linked')
      private_dir = File.join(alpha, '.git', 'worktrees', 'linked')
      FileUtils.mkdir_p([linked, private_dir])
      File.write(File.join(linked, '.git'), "gitdir: #{private_dir}\n")
      File.write(File.join(private_dir, 'HEAD'), "ref: refs/heads/topic\n")
      detached = checkout('checkout-detached', branch: nil)

      expect(Woods::MCP::ServedIdentity.checkout_branch(linked)).to eq('topic')
      expect(Woods::MCP::ServedIdentity.checkout_branch(detached)).to be_nil
      expect(Woods::MCP::ServedIdentity.read(index_of(detached), cwd: detached).branch_matches).to be_nil
    end
  end

  describe 'woods-mcp-start' do
    let(:wrapper) { File.expand_path('../../exe/woods-mcp-start', __dir__) }

    # Runs the real launcher with exec intercepted (exit 42 = it would exec).
    def launch(index_dir, cwd:, args: [], env: {})
      harness = <<~RUBY
        wrapper, *argv = ARGV
        ARGV.replace(argv)
        Kernel.define_method(:exec) do |*|
          $stderr.puts "ALLOW=\#{ENV['WOODS_MCP_ALLOW_MISMATCH']}"
          exit 42
        end
        load wrapper
      RUBY
      env = { 'WOODS_MCP_ALLOW_MISMATCH' => nil }.merge(env)
      _out, errors, status = Open3.capture3(env, RbConfig.ruby, '-e', harness, wrapper, *args, index_dir, chdir: cwd)
      [status.exitstatus, errors]
    end

    it 'connects in its own checkout without warnings' do
      alpha = checkout('checkout-alpha')

      code, errors = launch(index_of(alpha), cwd: alpha)

      expect(code).to eq(42), errors
      expect(errors).not_to include('Warning', 'Error')
    end

    it "refuses another checkout's index, naming both roots" do
      alpha = checkout('checkout-alpha')
      beta = checkout('checkout-beta')

      code, errors = launch(index_of(alpha), cwd: beta)

      expect(code).to eq(1)
      expect(errors).to include("written for the checkout at #{alpha}", "launched in #{beta}",
                                '--allow-mismatch', 'WOODS_MCP_ALLOW_MISMATCH=1')
    end

    it 'connects with a warning under --allow-mismatch or WOODS_MCP_ALLOW_MISMATCH=1' do
      alpha = checkout('checkout-alpha')
      beta = checkout('checkout-beta')

      [{ args: ['--allow-mismatch'] }, { env: { 'WOODS_MCP_ALLOW_MISMATCH' => '1' } }].each do |override|
        code, errors = launch(index_of(alpha), cwd: beta, **override)

        expect(code).to eq(42), errors
        expect(errors).to include("Warning: serving another checkout's index", alpha, beta, 'ALLOW=1')
      end
    end

    it 'warns on a branch difference but connects' do
      alpha = checkout('checkout-alpha', branch: 'main')
      File.write(File.join(alpha, '.git', 'HEAD'), "ref: refs/heads/topic\n")

      code, errors = launch(index_of(alpha), cwd: alpha)

      expect(code).to eq(42), errors
      expect(errors).to include('Warning: The index was extracted on branch main; this checkout is on topic.')
    end

    it 'warns about an index another Woods version wrote' do
      alpha = checkout('checkout-alpha', manifest: { 'woods_version' => '0.0.1' })

      code, errors = launch(index_of(alpha), cwd: alpha)

      expect(code).to eq(42), errors
      expect(errors).to include("Index written by Woods 0.0.1, this reader is #{Woods::VERSION}")
    end
  end

  describe 'writer and reader builds' do
    # Corrupt one unit the way a payload format change would look to this
    # reader: its identity guard rejects the unit.
    def break_unit(root)
      path = Dir.glob(File.join(index_of(root), 'payloads', '*', 'models', 'Post_*.json')).first
      File.write(path, JSON.generate(JSON.parse(File.read(path)).merge('type' => 'format_from_another_build')))
    end

    # recent_changes reads every model through the typed identity guard.
    def lookup_text(server)
      call(server, 'recent_changes', types: ['model'])
    end

    it 'reports a version gap instead of typed unit identity mismatch' do
      alpha = checkout('checkout-alpha', manifest: { 'woods_version' => '2.1.0' })
      break_unit(alpha)
      server = Dir.chdir(alpha) { build_server(index_of(alpha)) }

      result = lookup_text(server)
      text = result.dig('content', 0, 'text')

      expect(result['isError']).to be(true)
      expect(text).to eq("Index written by Woods 2.1.0, this reader is #{Woods::VERSION}; " \
                         'run `woods:extract` or request a re-index.')
      expect(text).not_to include('typed unit identity mismatch')
      expect(result.dig('_meta', 'error_code')).to eq('index_build_mismatch')
      expect(Dir.chdir(alpha) { instructions(server) }).to include('WARNING: Index written by Woods 2.1.0')
      expect(status(server).dig('identity', 'build', 'state')).to eq('version_mismatch')
    end

    it 'keeps the typed unit identity mismatch for an index this build wrote' do
      alpha = checkout('checkout-alpha')
      break_unit(alpha)
      allow(Woods::BuildIdentity).to receive(:current).and_return(released)

      reader = Woods::MCP::IndexReader.new(index_of(alpha))
      reader.manifest

      expect { reader.send(:load_search_unit, 'model', 'Post') }
        .to raise_error(IOError, /typed unit identity mismatch/)
    end

    it 'reports a different Woods build for the same version string at another revision' do
      alpha = checkout('checkout-alpha', manifest: { 'woods_revision' => writer_revision,
                                                     'woods_revision_dirty' => false })
      break_unit(alpha)
      reader_build = instance_double(Woods::BuildIdentity, version: Woods::VERSION, revision: 'b' * 40, dirty: false)
      allow(Woods::BuildIdentity).to receive(:current).and_return(reader_build)
      server = Dir.chdir(alpha) { build_server(index_of(alpha)) }

      text = lookup_text(server).dig('content', 0, 'text')
      report = status(server)

      expect(text).to start_with("Index written by a different Woods build (#{'a' * 12}); " \
                                 "this reader is #{'b' * 12}, both #{Woods::VERSION}.")
      expect(report.dig('identity', 'woods_revision')).to eq(writer_revision)
      expect(report.dig('identity', 'build', 'state')).to eq('build_mismatch')
      expect(Dir.chdir(alpha) { instructions(server) })
        .to include("written by Woods #{Woods::VERSION} (#{'a' * 12})",
                    'WARNING: Index written by a different Woods build')
    end

    it 'explains incremental readiness as a build mismatch, never as needing a full extraction' do
      alpha = checkout('checkout-alpha', manifest: { 'woods_revision' => writer_revision })
      payload = Dir.glob(File.join(index_of(alpha), 'payloads', '*')).first
      File.write(File.join(payload, Woods::SourceReferences::Cache::FILE_NAME),
                 JSON.generate(version: 999, callers: {}, files: {}, owners: {}))
      reader_build = instance_double(Woods::BuildIdentity, version: Woods::VERSION, revision: 'b' * 40, dirty: true)

      result = Woods::Resilience::IncrementalReadiness.new(index_dir: index_of(alpha), build: reader_build).call

      expect(result).not_to be_ready
      expect(result.cause).to eq('build_mismatch')
      expect(result.to_s).to start_with("build mismatch (Index written by a different Woods build (#{'a' * 12})")
      expect(result.to_s).to include("this reader is #{'b' * 12}-dirty")
      expect(result.to_s).not_to include('needs full extraction')

      released_result = Woods::Resilience::IncrementalReadiness.new(index_dir: index_of(alpha), build: released).call
      expect(released_result.to_s).to start_with('needs full extraction (the source reference cache is unusable')
    end

    it 'behaves as before for a released gem, which records no revision' do
      alpha = checkout('checkout-alpha', manifest: { 'woods_revision' => nil, 'woods_revision_dirty' => nil })
      allow(Woods::BuildIdentity).to receive(:current).and_return(released)

      identity = Woods::MCP::ServedIdentity.read(index_of(alpha), cwd: alpha)

      expect(identity.compatibility.state).to eq('same_version')
      expect(identity.warnings).to be_empty
      expect(identity.summary).to end_with("written by Woods #{Woods::VERSION}.")
    end

    it 'compares nothing a git-loaded reader would need git for when the writer records no revision' do
      reader_build = instance_double(Woods::BuildIdentity, version: Woods::VERSION)
      expect(reader_build).not_to receive(:revision)

      comparison = Woods::BuildIdentity.compare({ 'woods_version' => Woods::VERSION }, reader: reader_build)

      expect(comparison.state).to eq('same_version')
    end
  end
end
