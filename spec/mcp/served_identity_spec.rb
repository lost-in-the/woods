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

      expect(text.lines[0]).to start_with("WARNING: This index describes #{alpha}, not the launch checkout #{beta}")
      expect(text.lines[1]).to start_with('Serving the index of checkout-alpha')
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
      expect(unreachable.warnings.size).to eq(1)
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
      env = { 'WOODS_MCP_ALLOW_MISMATCH' => nil, 'WOODS_MCP_CLIENT_ROOT' => nil,
              'WOODS_MCP_CLIENT_ROOT_MAP' => nil }.merge(env)
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

    it 'hands --allow-mismatch to an awaiting server, which judges a generation published later' do
      alpha = checkout('checkout-alpha')
      FileUtils.rm_r(index_of(alpha))

      code, errors = launch(index_of(alpha), cwd: alpha, args: ['--await-index', '--allow-mismatch'])

      expect(code).to eq(42), errors
      expect(errors).to include('ALLOW=1')
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

    # A launcher that crosses into a shared container runs in the checkout the
    # container mounts, so its own directory always matches the index there.
    # Only the client root the session hands over can tell the two apart.
    describe 'with the client root of a session in another checkout' do
      { 'the environment' => ->(root) { { env: { 'WOODS_MCP_CLIENT_ROOT' => root } } },
        'the flag' => ->(root) { { args: ['--client-root', root] } },
        'the flag with =' => ->(root) { { args: ["--client-root=#{root}"] } } }.each do |form, declare|
        it "refuses when the launch directory matches the index but the client root, given by #{form}, does not" do
          alpha = checkout('checkout-alpha')
          beta = checkout('checkout-beta')

          code, errors = launch(index_of(alpha), cwd: alpha, **declare.call(beta))

          expect(code).to eq(1), errors
          expect(errors).to include("written for the checkout at #{alpha}", "launched in #{beta}",
                                    '--allow-mismatch')
        end
      end

      it 'connects with one warning when there is no map and the client root does not exist here' do
        alpha = checkout('checkout-alpha')

        code, errors = launch(index_of(alpha), cwd: alpha, args: ['--client-root', '/host-only/checkout-beta'])

        expect(code).to eq(42), errors
        expect(errors.lines.grep(/Warning/).size).to eq(1)
        expect(errors).to include("the client's checkout is unknown", '/host-only/checkout-beta',
                                  '--client-root-map')
      end

      it 'connects without a warning when the client root is the served checkout' do
        alpha = checkout('checkout-alpha')

        code, errors = launch(index_of(alpha), cwd: File.join(alpha, 'tmp'), args: ['--client-root', alpha])

        expect(code).to eq(42), errors
        expect(errors).not_to include('Warning', 'Error')
      end
    end

    # A map describes a bind mount, which is the same for every session; the
    # client root is the session's own directory on the client's side.
    describe 'with a client root map' do
      it 'translates a client root under a mapped prefix and serves its own checkout without a warning' do
        alpha = checkout('checkout-alpha')

        code, errors = launch(index_of(alpha), cwd: alpha,
                                               args: ['--client-root', '/host/wts/checkout-alpha',
                                                      '--client-root-map', "/host/wts=#{@base}"])

        expect(code).to eq(42), errors
        expect(errors).not_to include('Warning', 'Error')
      end

      it 'refuses the index of the mounted checkout for a session in another mapped worktree' do
        alpha = checkout('checkout-alpha')
        checkout('checkout-beta')

        code, errors = launch(index_of(alpha), cwd: alpha,
                                               args: ['--client-root', '/host/wts/checkout-beta',
                                                      "--client-root-map=/host/wts=#{@base}"])

        expect(code).to eq(1), errors
        expect(errors).to include("written for the checkout at #{alpha}",
                                  "launched in #{File.join(@base, 'checkout-beta')}")
      end

      it 'refuses a client root under no mapped prefix, naming it, and serves it under --allow-mismatch' do
        alpha = checkout('checkout-alpha')
        args = ['--client-root', '/host/checkout-beta', '--client-root-map', "/host/checkout-alpha=#{alpha}"]

        refused, refusal = launch(index_of(alpha), cwd: alpha, args: args)
        allowed, warning = launch(index_of(alpha), cwd: alpha, args: ['--allow-mismatch', *args])

        expect(refused).to eq(1), refusal
        expect(refusal).to include('/host/checkout-beta', 'no --client-root-map prefix', 'no mount covers it',
                                   '--allow-mismatch', 'WOODS_MCP_ALLOW_MISMATCH=1')
        expect(allowed).to eq(42), warning
        expect(warning).to include("Warning: serving another checkout's index", '/host/checkout-beta', 'ALLOW=1')
      end

      it 'matches whole path segments only: /host/wt-a does not cover /host/wt-ab' do
        alpha = checkout('checkout-alpha')

        args = ['--client-root', '/host/wt-ab', '--client-root-map', "/host/wt-a=#{alpha}"]
        code, errors = launch(index_of(alpha), cwd: alpha, args: args)

        expect(code).to eq(1), errors
        expect(errors).to include('/host/wt-ab', 'no --client-root-map prefix')
      end

      it 'takes the longest prefix, ignores trailing slashes, and reads entries from the environment' do
        alpha = checkout('checkout-alpha')
        map = "/host=#{@base}/nowhere:/host/wts/=#{@base}/"

        code, errors = launch(index_of(alpha), cwd: alpha,
                                               env: { 'WOODS_MCP_CLIENT_ROOT' => '/host/wts/checkout-alpha/',
                                                      'WOODS_MCP_CLIENT_ROOT_MAP' => map })

        expect(code).to eq(42), errors
        expect(errors).not_to include('Warning', 'Error')
      end

      it 'refuses a mapped client root that does not exist here: the mount does not hold that session' do
        alpha = checkout('checkout-alpha')
        args = ['--client-root', '/host/wts/checkout-gone', '--client-root-map', "/host/wts=#{@base}"]

        refused, refusal = launch(index_of(alpha), cwd: alpha, args: args)
        allowed, warning = launch(index_of(alpha), cwd: alpha, args: ['--allow-mismatch', *args])

        expect(refused).to eq(1), refusal
        expect(refusal).to include('/host/wts/checkout-gone', File.join(@base, 'checkout-gone'), 'does not exist here',
                                   '--allow-mismatch')
        expect(allowed).to eq(42), warning
      end

      it 'warns once for a mapped client root that exists here outside any checkout' do
        alpha = checkout('checkout-alpha')
        FileUtils.mkdir_p(File.join(@base, 'plain'))

        code, errors = launch(index_of(alpha), cwd: alpha,
                                               args: ['--client-root', '/host/wts/plain', '--client-root-map',
                                                      "/host/wts=#{@base}"])

        expect(code).to eq(42), errors
        expect(errors.lines.grep(/Warning/).size).to eq(1)
        expect(errors).to include('/host/wts/plain', 'is not inside a git checkout here')
      end

      it 'refuses a map flag without a client root, and a client root given twice' do
        alpha = checkout('checkout-alpha')

        map_only, map_error = launch(index_of(alpha), cwd: alpha, args: ['--client-root-map', "/host=#{@base}"])
        twice, twice_error = launch(index_of(alpha), cwd: alpha, args: ['--client-root', '/a', '--client-root=/b'])

        expect([map_only, twice]).to eq([1, 1])
        expect(map_error).to include('--client-root-map needs --client-root')
        expect(twice_error).to include('--client-root given more than once')
      end

      it 'ignores a map exported in the environment, with one warning, when no client root is given' do
        alpha = checkout('checkout-alpha')

        code, errors = launch(index_of(alpha), cwd: alpha, env: { 'WOODS_MCP_CLIENT_ROOT_MAP' => "/host=#{@base}" })

        expect(code).to eq(42), errors
        expect(errors.lines.grep(/Warning/)).to eq(['Warning: WOODS_MCP_CLIENT_ROOT_MAP is set but no client root ' \
                                                    "was given; ignoring the map.\n"])
      end

      it 'refuses a malformed map entry at startup' do
        alpha = checkout('checkout-alpha')

        ['nope', 'relative=/app', '/host=relative', '/host=', '/host=/app=/srv'].each do |entry|
          code, errors = launch(index_of(alpha), cwd: alpha,
                                                 args: ['--client-root', '/host/x', "--client-root-map=#{entry}"])

          expect(code).to eq(1), entry
          expect(errors).to include('--client-root-map', 'HOST_PREFIX=CONTAINER_PREFIX'), entry
        end
      end

      it 'refuses a relative client root and an empty one' do
        alpha = checkout('checkout-alpha')

        relative, relative_error = launch(index_of(alpha), cwd: alpha, args: ['--client-root', 'checkout-beta'])
        empty, empty_error = launch(index_of(alpha), cwd: alpha, args: ['--client-root='])

        expect([relative, empty]).to eq([1, 1])
        expect(relative_error).to include('--client-root must be an absolute path')
        expect(empty_error).to include('--client-root needs a path')
      end
    end

    describe 'ServedIdentity.map_client_root' do
      let(:map) { Woods::MCP::ServedIdentity.parse_client_root_map('/host=/a:/host/wts=/b:/=/root-mount') }

      it 'derives the path through the longest whole-segment prefix, and the root prefix last' do
        expect(Woods::MCP::ServedIdentity.map_client_root('/host/wts/topic', map))
          .to eq(['/b/topic', ['/host/wts', '/b']])
        expect(Woods::MCP::ServedIdentity.map_client_root('/host/wtsx', map)).to eq(['/a/wtsx', ['/host', '/a']])
        expect(Woods::MCP::ServedIdentity.map_client_root('/host/wts', map)).to eq(['/b', ['/host/wts', '/b']])
        expect(Woods::MCP::ServedIdentity.map_client_root('/elsewhere/x', map))
          .to eq(['/root-mount/elsewhere/x', ['/', '/root-mount']])
      end

      it 'collapses repeated leading slashes and compares case-sensitively' do
        map = Woods::MCP::ServedIdentity.parse_client_root_map('//host/wts=/b')

        expect(Woods::MCP::ServedIdentity.map_client_root('//host/wts/topic', map))
          .to eq(['/b/topic', ['/host/wts', '/b']])
        expect(Woods::MCP::ServedIdentity.map_client_root('/Host/wts/topic', map)).to be_nil
      end

      it 'answers nil under no prefix' do
        single = Woods::MCP::ServedIdentity.parse_client_root_map('/host/wt-a=/app')

        expect(Woods::MCP::ServedIdentity.map_client_root('/host/wt-ab', single)).to be_nil
        expect(Woods::MCP::ServedIdentity.map_client_root('/host/wt-a/app/models', single))
          .to eq(['/app/app/models', ['/host/wt-a', '/app']])
      end
    end
  end

  describe 'a client checkout that cannot be determined' do
    def with_env(values)
      saved = values.keys.to_h { |key| [key, ENV.fetch(key, nil)] }
      values.each { |key, value| ENV[key] = value }
      yield
    ensure
      saved.each { |key, value| ENV[key] = value }
    end

    it 'names the unknown side in one WARNING line of the instructions and of woods_status' do
      alpha = checkout('checkout-alpha')
      host = '/host-only/checkout-beta'

      text, report = with_env('WOODS_MCP_CLIENT_ROOT' => host, 'WOODS_MCP_CLIENT_ROOT_MAP' => nil) do
        Dir.chdir(alpha) { [instructions(build_server(index_of(alpha))), status(build_server(index_of(alpha)))] }
      end

      warning = text.lines.grep(/\AWARNING: /)
      expect(warning.size).to eq(1)
      expect(warning.first).to include("the client's checkout is unknown", host)
      expect(report.fetch('identity')).to include('client_matches' => nil,
                                                  'client_match_reason' => 'client_root_unresolved',
                                                  'client_root' => nil, 'client_root_declared' => host,
                                                  'warnings' => [warning.first.delete_prefix('WARNING: ').chomp])
    end

    it 'names the served checkout by the declared client root when it matches through a mapping' do
      alpha = checkout('checkout-alpha')
      host = '/host-only/checkout-alpha'

      text, identity = with_env('WOODS_MCP_CLIENT_ROOT' => host,
                                'WOODS_MCP_CLIENT_ROOT_MAP' => "/host-only=#{@base}") do
        Dir.chdir(@base) do
          [instructions(build_server(index_of(alpha))), status(build_server(index_of(alpha))).fetch('identity')]
        end
      end

      expect(text.lines.first).to start_with("Serving the index of checkout-alpha (#{host}, mapped to #{alpha}), ")
      expect(identity).to include('client_matches' => true, 'client_root' => alpha, 'client_root_declared' => host,
                                  'client_root_map_entry' => "/host-only=#{@base}", 'client_root_mapped_to' => alpha,
                                  'warnings' => [])
    end

    it 'names a session in a subdirectory by its checkout, not by the subdirectory' do
      alpha = checkout('checkout-alpha')
      FileUtils.mkdir_p(File.join(alpha, 'app', 'models'))

      text = with_env('WOODS_MCP_CLIENT_ROOT' => '/host-only/checkout-alpha/app/models',
                      'WOODS_MCP_CLIENT_ROOT_MAP' => "/host-only=#{@base}") do
        Dir.chdir(@base) { instructions(build_server(index_of(alpha))) }
      end

      expect(text.lines.first)
        .to start_with("Serving the index of checkout-alpha (/host-only/checkout-alpha, mapped to #{alpha}), ")
    end

    it 'reports a client root under no mapped prefix as a mismatch with a warning' do
      alpha = checkout('checkout-alpha')

      text, identity = with_env('WOODS_MCP_CLIENT_ROOT' => '/host/checkout-beta',
                                'WOODS_MCP_CLIENT_ROOT_MAP' => "/host/checkout-alpha=#{alpha}") do
        Dir.chdir(alpha) do
          [instructions(build_server(index_of(alpha))), status(build_server(index_of(alpha))).fetch('identity')]
        end
      end

      expect(text.lines.grep(/\AWARNING: /).first).to include('/host/checkout-beta', 'no --client-root-map prefix')
      expect(identity).to include('client_matches' => false, 'client_match_reason' => 'client_root_unmapped',
                                  'client_root' => nil, 'client_root_mapped_to' => nil)
    end

    it 'warns, naming the variable, when the map in the environment is malformed' do
      alpha = checkout('checkout-alpha')

      identity = with_env('WOODS_MCP_CLIENT_ROOT' => '/host/x', 'WOODS_MCP_CLIENT_ROOT_MAP' => 'nope') do
        Woods::MCP::ServedIdentity.read(index_of(alpha))
      end

      expect(identity.client_matches).to be_nil
      expect(identity.warnings.first).to include('WOODS_MCP_CLIENT_ROOT_MAP is malformed')
    end

    it 'warns for a launch outside any checkout and for an index whose checkout is unreachable' do
      alpha = checkout('checkout-alpha')
      outside = File.join(@base, 'plain-directory')
      FileUtils.mkdir_p(outside)
      detached_index = File.join(@base, 'indexes', 'copy')
      FileUtils.mkdir_p(File.dirname(detached_index))
      FileUtils.cp_r(index_of(alpha), detached_index)

      client = Woods::MCP::ServedIdentity.read(index_of(alpha), cwd: outside)
      unreachable = Woods::MCP::ServedIdentity.read(detached_index, cwd: alpha,
                                                                    manifest: { 'root' => '/nonexistent-root/app' })
      unrecorded = Woods::MCP::ServedIdentity.read(detached_index, cwd: alpha, manifest: {})

      expect(client.warnings).to eq(["The launch directory #{outside} is not inside a git checkout, so this " \
                                     "index was not compared with the client's checkout (pass --client-root " \
                                     'to compare them).'])
      expect(unreachable.warnings.size).to eq(1)
      expect(unreachable.warnings.first).to include("the index's checkout is unknown", '/nonexistent-root/app')
      expect(unrecorded.warnings.size).to eq(1)
      expect(unrecorded.warnings.first).to include("the index's checkout is unknown", 'records no root',
                                                   detached_index)
    end

    it 'keeps the first instructions line unchanged when no client root is declared' do
      alpha = checkout('checkout-alpha', branch: 'main', generation: 3)

      text = with_env('WOODS_MCP_CLIENT_ROOT' => nil, 'WOODS_MCP_CLIENT_ROOT_MAP' => nil) do
        Dir.chdir(alpha) { instructions(build_server(index_of(alpha))) }
      end

      expect(text.lines.first).to eq(
        "Serving the index of checkout-alpha (#{alpha}), branch main, generation 3, " \
        "updated 2026-11-01T10:00:00Z, written by Woods #{Woods::VERSION}.\n"
      )
    end

    it 'describes a routed worktree by its root, never by the declared client root' do
      alpha = checkout('checkout-alpha')

      identity = with_env('WOODS_MCP_CLIENT_ROOT' => '/host-only/elsewhere', 'WOODS_MCP_CLIENT_ROOT_MAP' => nil) do
        route = Struct.new(:root).new(alpha)
        Thread.current[Woods::MCP::WorktreeRouting::THREAD_KEY] = route
        Woods::MCP::Server.identity_section(index_of(alpha), nil)
      ensure
        Thread.current[Woods::MCP::WorktreeRouting::THREAD_KEY] = nil
      end

      expect(identity).to include(client_matches: true, client_root: alpha, client_root_declared: nil)
    end
  end

  # A container launch with no mount map cannot read the client's checkout:
  # the host path does not exist here. The wrapper hands over what the
  # client's checkout is instead, with no path in it: worktree kind, HEAD and
  # branch, as "kind:sha:branch". A difference from the checkout this server
  # serves is a mismatch; agreement serves as before, with the warning.
  describe 'the client identity a container launch hands over' do
    let(:sha) { 'a' * 40 }

    def with_env(values)
      saved = values.keys.to_h { |key| [key, ENV.fetch(key, nil)] }
      values.each { |key, value| ENV[key] = value }
      yield
    ensure
      saved.each { |key, value| ENV[key] = value }
    end

    def at_head(root, sha, branch: 'main', packed: false)
      git = File.join(root, '.git')
      File.write(File.join(git, 'HEAD'), branch ? "ref: refs/heads/#{branch}\n" : "#{sha}\n")
      return unless branch

      if packed
        File.write(File.join(git, 'packed-refs'),
                   "# pack-refs with: peeled fully-peeled sorted\n#{sha} refs/heads/#{branch}\n")
      else
        FileUtils.mkdir_p(File.join(git, 'refs', 'heads'))
        File.write(File.join(git, 'refs', 'heads', branch), "#{sha}\n")
      end
    end

    def identity(alpha, declared)
      with_env('WOODS_MCP_CLIENT_ROOT' => '/host-only/checkout-x', 'WOODS_MCP_CLIENT_ROOT_MAP' => nil,
               'WOODS_MCP_CLIENT_IDENTITY' => declared) do
        Woods::MCP::ServedIdentity.read(index_of(alpha))
      end
    end

    it 'serves as before when the client is the same kind of checkout at the same HEAD and branch' do
      alpha = checkout('checkout-alpha')
      at_head(alpha, sha)

      result = identity(alpha, "main:#{sha}:main")

      expect([result.client_matches, result.match_reason]).to eq([nil, 'client_root_unresolved'])
      expect(result.to_h).to include(client_branch: 'main', client_identity: { worktree: 'main', head: sha,
                                                                               branch: 'main' })
    end

    it 'agrees through a packed ref, a detached client and a detached served checkout' do
      packed = checkout('checkout-packed')
      at_head(packed, sha, packed: true)
      detached = checkout('checkout-detached', branch: nil)
      at_head(detached, sha, branch: nil)

      expect(identity(packed, "main:#{sha}:main").match_reason).to eq('client_root_unresolved')
      expect(identity(packed, "main:#{sha}:").match_reason).to eq('client_root_unresolved')
      expect(identity(detached, "main:#{sha}:topic").match_reason).to eq('client_root_unresolved')
    end

    {
      'a linked worktree against the main checkout' => ->(sha) { "linked:#{sha}:main" },
      'another HEAD' => ->(_sha) { "main:#{'b' * 40}:main" },
      'another branch at the same HEAD' => ->(sha) { "main:#{sha}:topic" }
    }.each do |label, declared|
      it "refuses #{label}, naming the map and the override" do
        alpha = checkout('checkout-alpha')
        at_head(alpha, sha)

        result = identity(alpha, declared.call(sha))

        expect([result.client_matches, result.match_reason]).to eq([false, 'client_identity_differs'])
        expect(result.refusal_message).to include('/host-only/checkout-x', 'WOODS_MCP_CLIENT_ROOT_MAP',
                                                  '--allow-mismatch', alpha)
      end
    end

    it 'compares nothing when the served application has no .git, as in a mount of the app directory alone' do
      app = checkout('app-only')
      FileUtils.rm_rf(File.join(app, '.git'))

      result = identity(app, "main:#{sha}:main")

      expect(result.client_matches).to be_nil
      expect(result.match_reason).not_to eq('client_identity_differs')
    end

    it 'compares nothing for a malformed identity, or when the client root resolves' do
      alpha = checkout('checkout-alpha')
      at_head(alpha, sha)
      resolved = with_env('WOODS_MCP_CLIENT_ROOT' => alpha, 'WOODS_MCP_CLIENT_IDENTITY' => "linked:#{sha}:x") do
        Woods::MCP::ServedIdentity.read(index_of(alpha))
      end

      expect(identity(alpha, 'nonsense').match_reason).to eq('client_root_unresolved')
      expect(resolved.match_reason).to eq('same_checkout')
    end

    describe 'woods-mcp-start --client-identity' do
      let(:wrapper) { File.expand_path('../../exe/woods-mcp-start', __dir__) }

      def launch(index_dir, cwd:, args: [])
        harness = <<~RUBY
          wrapper, *argv = ARGV
          ARGV.replace(argv)
          Kernel.define_method(:exec) { |*| exit 42 }
          load wrapper
        RUBY
        env = { 'WOODS_MCP_ALLOW_MISMATCH' => nil, 'WOODS_MCP_CLIENT_ROOT' => nil, 'WOODS_MCP_CLIENT_ROOT_MAP' => nil,
                'WOODS_MCP_CLIENT_IDENTITY' => nil }
        _out, errors, status = Open3.capture3(env, RbConfig.ruby, '-e', harness, wrapper, *args, index_dir,
                                              chdir: cwd)
        [status.exitstatus, errors]
      end

      it 'refuses a differing client and serves an agreeing one' do
        alpha = checkout('checkout-alpha')
        at_head(alpha, sha)
        client = ['--client-root', '/host-only/checkout-x']

        refused, refusal = launch(index_of(alpha), cwd: alpha, args: [*client, '--client-identity', "linked:#{sha}:"])
        served, warning = launch(index_of(alpha), cwd: alpha, args: [*client, "--client-identity=main:#{sha}:main"])
        allowed, = launch(index_of(alpha), cwd: alpha,
                                           args: ['--allow-mismatch', *client, '--client-identity', "linked:#{sha}:"])

        expect(refused).to eq(1), refusal
        expect(refusal).to include('WOODS_MCP_CLIENT_ROOT_MAP', '--allow-mismatch')
        expect(served).to eq(42), warning
        expect(allowed).to eq(42)
      end

      it 'refuses a malformed identity and one without a client root' do
        alpha = checkout('checkout-alpha')

        malformed, malformed_error = launch(index_of(alpha), cwd: alpha,
                                                             args: ['--client-root', '/host-only/x',
                                                                    '--client-identity', 'sideways:zz:main'])
        orphan, orphan_error = launch(index_of(alpha), cwd: alpha, args: ['--client-identity', 'main::'])

        expect([malformed, orphan]).to eq([1, 1])
        expect(malformed_error).to include('--client-identity', 'main|linked')
        expect(orphan_error).to include('--client-identity needs --client-root')
      end
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
  # A publication can land between two reads of one identity: the pin and the
  # identity block in woods_status, or the marker and the manifest at startup.
  # Every identity field must then still describe one snapshot.
  describe 'a generation published between reads' do
    let(:first) { { 'git_sha' => '1' * 40, 'woods_version' => Woods::VERSION, 'woods_revision' => '1' * 40 } }
    let(:second) { { 'git_sha' => '2' * 40, 'woods_version' => '0.0.2-next', 'woods_revision' => '2' * 40 } }

    def publish(root, generation, manifest)
      index = index_of(root)
      payload = File.join(index, 'payloads', "gen-#{generation}")
      FileUtils.cp_r(Dir.glob(File.join(index, 'payloads', '*')).first, payload)
      recorded = JSON.parse(File.read(File.join(payload, 'manifest.json'))).merge(manifest)
      File.write(File.join(payload, 'manifest.json'), JSON.generate(recorded))
      File.write(File.join(index, 'generation.json'),
                 JSON.generate(number: generation, token: "t#{generation}", updated_at: '2026-11-02T10:00:00Z',
                               reason: 'extract', payload: "payloads/gen-#{generation}"))
    end

    def expect_first_snapshot(identity)
      expect(identity.transform_keys(&:to_s)).to include(
        'generation' => 1, 'generation_updated_at' => '2026-11-01T10:00:00Z', 'git_sha' => '1' * 40,
        'woods_version' => Woods::VERSION, 'woods_revision' => '1' * 40
      )
    end

    it 'reports the pinned generation in woods_status, never the one published after the pin' do
      alpha = checkout('checkout-alpha', manifest: first)
      server = Dir.chdir(alpha) { build_server(index_of(alpha)) }
      reader = server.instance_variable_get(:@woods_index_reader)
      allow(Woods::MCP::Server).to receive(:identity_section).and_wrap_original do |original, *args|
        publish(alpha, 2, second)
        original.call(*args)
      end

      identity = Dir.chdir(alpha) { status(server) }.fetch('identity')

      expect(reader.loaded_generation).to eq(1)
      expect_first_snapshot(identity)
    end

    it 'resolves the startup manifest from the one marker it read' do
      alpha = checkout('checkout-alpha', manifest: first)
      published = false
      allow_any_instance_of(Woods::Generation).to receive(:current).and_wrap_original do |original, *args|
        original.call(*args).tap do
          publish(alpha, 2, second) unless published
          published = true
        end
      end

      identity = Woods::MCP::ServedIdentity.read(index_of(alpha), cwd: alpha)

      expect_first_snapshot(identity.to_h)
      expect(identity.summary).to include('generation 1, updated 2026-11-01T10:00:00Z', "(#{'1' * 12})")
    end
  end
end
