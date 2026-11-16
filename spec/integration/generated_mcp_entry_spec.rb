# frozen_string_literal: true

require 'spec_helper'
require 'bundler'
require 'fileutils'
require 'json'
require 'open3'
require 'timeout'
require 'tmpdir'
require 'woods/gem_mapper'
require 'woods/mcp/client_entry'

# The `.mcp.json` entry `rails generate woods:install --mcp-config` writes,
# committed once and launched exactly as written, from a subdirectory of the
# checkout and from a linked worktree: each serves its own checkout's index.
RSpec.describe 'The generated MCP entry' do
  let(:repo) { File.expand_path('../..', __dir__) }
  let(:fixture_dir) { File.expand_path('../fixtures/woods', __dir__) }

  around do |example|
    Dir.mktmpdir('woods-generated-entry') do |directory|
      @base = File.realpath(directory)
      @app = File.join(@base, 'shop')
      example.run
    end
  end

  def git(dir, *args)
    output, status = Open3.capture2e('git', '-C', dir, *args)
    raise "git #{args.join(' ')} failed: #{output}" unless status.success?

    output
  end

  # An application repository whose own Gemfile resolves this Woods checkout.
  def application(*generator_args)
    FileUtils.mkdir_p(@app)
    git(@base, 'init', '-q', '-b', 'main', @app)
    File.write(File.join(@app, 'Gemfile'), "source 'https://rubygems.org'\ngem 'woods', path: #{repo.inspect}\n")
    generate(@app, '--mcp-config', *generator_args)
    git(@app, 'add', 'Gemfile', '.mcp.json')
    git(@app, '-c', 'user.name=Spec', '-c', 'user.email=spec@example.com', '-c', 'commit.gpgsign=false',
        'commit', '-q', '-m', 'Add Woods')
    JSON.parse(File.read(File.join(@app, '.mcp.json'))).dig('mcpServers', 'woods')
  end

  def generate(root, *arguments)
    gemfile = File.expand_path(ENV.fetch('BUNDLE_GEMFILE', 'Gemfile'), repo)
    environment = Bundler.unbundled_env.merge('BUNDLE_GEMFILE' => gemfile, 'BUNDLE_LOCKFILE' => "#{gemfile}.lock")
    script = <<~SCRIPT
      require 'bundler/setup'
      require 'generators/woods/install_generator'
      Woods::Generators::InstallGenerator.start(ARGV.drop(1), destination_root: ARGV.first)
    SCRIPT
    output, status = Open3.capture2e(environment, Gem.ruby, '-I', File.join(repo, 'lib'), '-e', script, root,
                                     *arguments)
    raise "generator failed: #{output}" unless status.success?
  end

  def publish(checkout)
    index = File.join(checkout, 'tmp', 'woods')
    FileUtils.mkdir_p(File.join(index, 'payloads'))
    FileUtils.cp_r(fixture_dir, File.join(index, 'payloads', 'gen-1'))
    File.write(File.join(index, 'generation.json'),
               JSON.generate(number: 1, token: 't1', updated_at: '2026-11-16T10:00:00Z', payload: 'payloads/gen-1'))
  end

  # The client's environment: no Bundler variables from this process, so the
  # application's own Gemfile is found from the working directory. Only
  # where gems are installed is carried over.
  def client_env(extra = {})
    env = Bundler.unbundled_env.reject { |key, _| key.start_with?('BUNDLE_') }
    installed = Bundler.settings[:path]
    env['BUNDLE_PATH'] = File.expand_path(installed, repo) if installed
    env.merge('WOODS_NO_UPDATE_CHECK' => '1', 'OLLAMA_BASE_URL' => 'http://127.0.0.1:0', 'OPENAI_API_KEY' => nil,
              'WOODS_DIR' => nil, 'WOODS_OUTPUT' => nil, 'WOODS_RETRIEVAL_MODE' => nil).merge(extra)
  end

  # The entry runs as a client runs it: its own `env` over the client's.
  def start(entry, cwd, env = {})
    @stdin, @stdout, @stderr, @wait = Open3.popen3(client_env(env).merge(entry.fetch('env', {})),
                                                   entry['command'], *entry['args'],
                                                   chdir: cwd, unsetenv_others: true)
    @errors = Thread.new { @stderr.read }
    @id = 0
    request('initialize', protocolVersion: '2025-06-18', capabilities: {},
                          clientInfo: { name: 'generated-entry', version: '1' })
  end

  def request(method, params = {})
    @id += 1
    @stdin.puts(JSON.generate(jsonrpc: '2.0', id: @id, method: method, params: params))
    @stdin.flush
    line = Timeout.timeout(120) { @stdout.gets }
    raise "no response to #{method}; stderr: #{stop}" unless line

    JSON.parse(line)
  end

  def lookup
    request('tools/call', name: 'lookup', arguments: { identifier: 'Post' }).fetch('result')
  end

  def stop
    @stdin.close unless @stdin.closed?
    Process.kill('TERM', @wait.pid) unless @wait.join(10)
    @wait.join(10)
    @errors.value.force_encoding(Encoding::UTF_8).scrub
  rescue Errno::ESRCH
    @errors.value.force_encoding(Encoding::UTF_8).scrub
  end

  def expect_found(result)
    expect(result['isError']).to be(false), result.dig('content', 0, 'text')
    expect(result.dig('structuredContent', 'data', 'status')).not_to eq('building')
    expect(result.dig('content', 0, 'text')).to include('Post')
  end

  it "serves the checkout's own index from a subdirectory and from a linked worktree, as written" do
    entry = application
    publish(@app)
    subdirectory = File.join(@app, 'app', 'models')
    FileUtils.mkdir_p(subdirectory)
    worktree = File.join(@base, 'shop-topic')
    git(@app, 'worktree', 'add', '-q', '-b', 'topic', worktree)

    start(entry, subdirectory)
    begin
      expect_found(lookup)
    ensure
      stop
    end

    start(entry, worktree)
    begin
      expect(lookup.dig('structuredContent', 'data', 'status')).to eq('building')
      publish(worktree)
      expect_found(lookup)
    ensure
      errors = stop
    end
    expect(errors).not_to include('Error')
  end

  # A stand-in for `docker` that records its argv and runs the command after
  # the service name in place, with the `-e` settings, as `compose exec` would
  # inside a container that mounts the same paths. Real Compose is not run.
  it 'runs the container entry through sh with the session directory as the client root' do
    @app = File.join(@base, 'my shop')
    entry = application('--mcp-service', 'web')
    publish(@app)
    stub_dir = File.join(@base, 'bin')
    FileUtils.mkdir_p(stub_dir)
    log = File.join(@base, 'docker-argv')
    File.write(File.join(stub_dir, 'docker'), <<~SH)
      #!/bin/sh
      printf '%s\\n' "$@" > "#{log}"
      while [ "$1" != "bundle" ]; do
        if [ "$1" = "-e" ]; then shift; export "$1"; fi
        shift
      done
      exec "$@"
    SH
    File.chmod(0o755, File.join(stub_dir, 'docker'))
    subdirectory = File.join(@app, 'app', 'models')
    FileUtils.mkdir_p(subdirectory)

    start(entry, subdirectory, 'PATH' => "#{stub_dir}:#{ENV.fetch('PATH')}")
    begin
      expect_found(lookup)
    ensure
      stop
    end

    expect(File.read(log).lines(chomp: true))
      .to eq(['compose', 'exec', '-T', '-e', 'WOODS_MCP_CLIENT_ROOT_MAP=', 'web', 'bundle', 'exec',
              'woods-mcp-start', '--checkout', '--await-index', '--client-root', subdirectory])
  end

  it 'starts in CLAUDE_PROJECT_DIR whatever directory the client starts it in' do
    entry = application
    worktree = File.join(@base, 'shop-topic')
    git(@app, 'worktree', 'add', '-q', '-b', 'topic', worktree)
    publish(@app)
    publish(worktree)

    [@app, worktree].each do |project|
      start(entry, @base, 'CLAUDE_PROJECT_DIR' => project)
      begin
        expect_found(lookup)
        report = JSON.parse(request('tools/call', name: 'woods_status', arguments: { worktrees: 'none' })
                              .dig('result', 'content', 0, 'text'))
        expect(report.dig('server', 'index_dir')).to eq(File.join(project, 'tmp', 'woods'))
      ensure
        stop
      end
    end
  end

  # Bundler looks for the Gemfile up from the working directory, never down:
  # the entry must reach an application below its checkout root from anywhere
  # the client may start it.
  it 'reaches an application below its checkout root from the checkout root, the app, a sibling and the project dir' do
    checkout = File.join(@base, 'mono repo')
    git(@base, 'init', '-q', '-b', 'main', checkout)
    @app = File.join(checkout, 'apps', 'my web')
    FileUtils.mkdir_p(@app)
    File.write(File.join(@app, 'Gemfile'), "source 'https://rubygems.org'\ngem 'woods', path: #{repo.inspect}\n")
    generate(@app, '--mcp-config')
    entry = JSON.parse(File.read(File.join(@app, '.mcp.json'))).dig('mcpServers', 'woods')
    publish(@app)
    sibling = File.join(checkout, 'apps', 'other')
    FileUtils.mkdir_p(sibling)

    [[checkout, {}], [@app, {}], [sibling, {}],
     [@base, { 'CLAUDE_PROJECT_DIR' => checkout }], [@base, { 'CLAUDE_PROJECT_DIR' => @app }]].each do |cwd, env|
      start(entry, cwd, env)
      begin
        expect_found(lookup)
        report = JSON.parse(request('tools/call', name: 'woods_status', arguments: { worktrees: 'none' })
                              .dig('result', 'content', 0, 'text'))
        expect(report.dig('server', 'index_dir')).to eq(File.join(@app, 'tmp', 'woods')), "#{cwd} #{env}"
      ensure
        stop
      end
    end
  end

  # The application's own lock, as an application commits it: resolved from
  # the installed gems, with its checksums. Bundler 4 leaves every CHECKSUMS
  # entry empty in a lock resolved locally, and the setup preflight runs
  # frozen, which refuses an empty entry. The entries are filled from the
  # cached archives, as spec/ci/ci_local_environment_spec.rb finalizes its
  # fixture locks.
  def lock_application(root)
    env = client_env('BUNDLE_GEMFILE' => File.join(root, 'Gemfile'))
    commands = [%w[bundle lock --local]]
    commands << [Gem.ruby, '-e', finalize_lock] if Gem::Version.new(Bundler::VERSION) >= Gem::Version.new('4')
    commands.each do |command|
      output, status = Open3.capture2e(env, *command, chdir: root, unsetenv_others: true)
      raise "#{command.first(2).join(' ')} failed: #{output}" unless status.success?
    end
  end

  def finalize_lock
    <<~'RUBY'
      require 'bundler'
      require 'rubygems/package'
      definition = Bundler.definition
      abort 'Bundler 4 lock must carry CHECKSUMS' unless definition.locked_checksums
      definition.sources.local_only!
      resolved = definition.resolve
      specs = resolved.materialize(definition.requested_dependencies)
      resolved.each do |locked|
        next unless locked.source.is_a?(Bundler::Source::Rubygems)

        spec = specs.find { |candidate| candidate.lock_name == locked.lock_name }
        archive = spec && spec.source.cached_built_in_gem(spec, local: true)
        abort "No cached archive for #{locked.full_name}" unless archive && File.file?(archive)
        spec.source.checksum_store.register(spec, Bundler::Checksum.from_gem_package(Gem::Package.new(archive)))
      end
      definition.lock
    RUBY
  end

  def agent_config(cwd, *arguments)
    output, status = Open3.capture2e(client_env, 'bundle', 'exec', 'woods-agent-config', *arguments,
                                     '--client', 'claude', '--scope', 'project', '--root', '.', chdir: cwd,
                                                                                                unsetenv_others: true)
    [output, status]
  end

  it 'launches the project entry woods-agent-config writes from the root, a subdirectory and a linked worktree' do
    FileUtils.mkdir_p(@app)
    git(@base, 'init', '-q', '-b', 'main', @app)
    File.write(File.join(@app, 'Gemfile'), "source 'https://rubygems.org'\ngem 'woods', path: #{repo.inspect}\n")
    lock_application(@app)
    # The setup preflight validates the index against the source it names, so
    # this checkout gets a real static map of its own one class.
    FileUtils.mkdir_p(File.join(@app, 'lib'))
    File.write(File.join(@app, 'lib', 'post.rb'), "class Post\n  def title; end\nend\n")
    Woods::GemMapper.new(root: @app, output_dir: File.join(@app, 'tmp', 'woods')).map!
    plans = File.join(@base, 'plans')
    FileUtils.mkdir_p(plans)
    output, status = agent_config(@app, 'setup', '--plan', File.join(plans, 'setup.json'))
    expect(status.success?).to be(true), output
    expect(JSON.parse(output[/^\{.*\}\s*\z/m])).to include('entry_form' => 'relative')
    output, status = agent_config(@app, 'apply', File.join(plans, 'setup.json'))
    expect(status.success?).to be(true), output
    entry = JSON.parse(File.read(File.join(@app, '.mcp.json'))).dig('mcpServers', 'woods')
    expect(entry).to eq(Woods::MCP::ClientEntry.checkout)
    expect(File.read(File.join(@app, '.mcp.json'))).not_to include(@base, '${')
    git(@app, 'add', 'Gemfile', 'Gemfile.lock', '.mcp.json')
    git(@app, '-c', 'user.name=Spec', '-c', 'user.email=spec@example.com', '-c', 'commit.gpgsign=false',
        'commit', '-q', '-m', 'Add Woods')
    worktree = File.join(@base, 'shop-topic')
    git(@app, 'worktree', 'add', '-q', '-b', 'topic', worktree)
    subdirectory = File.join(@app, 'app', 'models')
    FileUtils.mkdir_p(subdirectory)

    [[@app, {}], [subdirectory, {}], [@base, { 'CLAUDE_PROJECT_DIR' => @app }]].each do |cwd, env|
      start(entry, cwd, env)
      begin
        report = JSON.parse(request('tools/call', name: 'woods_status', arguments: { worktrees: 'none' })
                              .dig('result', 'content', 0, 'text'))
        expect(report).to include('ready' => true)
        expect(report.dig('server', 'index_dir')).to eq(File.join(@app, 'tmp', 'woods'))
      ensure
        stop
      end
    end
    start(entry, @base, 'CLAUDE_PROJECT_DIR' => worktree)
    begin
      expect(lookup.dig('structuredContent', 'data', 'status')).to eq('building')
      publish(worktree)
      expect_found(lookup)
    ensure
      stop
    end

    # The receipt is per-machine and not committed: setup in another checkout
    # adopts the committed, identical entry and records that checkout's own
    # receipt. (Its own static map lets the preflight validate an index.)
    FileUtils.rm_r(File.join(worktree, 'tmp', 'woods'))
    Woods::GemMapper.new(root: worktree, output_dir: File.join(worktree, 'tmp', 'woods')).map!
    output, status = agent_config(worktree, 'setup', '--plan', File.join(plans, 'worktree.json'))
    expect(status.success?).to be(true), output
    expect(JSON.parse(output[/^\{.*\}\s*\z/m])).to include('adopted' => true)
    output, status = agent_config(worktree, 'apply', File.join(plans, 'worktree.json'))
    expect(status.success?).to be(true), output
    expect(JSON.parse(File.read(File.join(worktree, '.woods-agent-config.json'))).dig('layout', 'root'))
      .to eq(worktree)
    expect(git(worktree, 'status', '--porcelain', '.mcp.json')).to be_empty
  end
end
