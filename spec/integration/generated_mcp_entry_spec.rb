# frozen_string_literal: true

require 'spec_helper'
require 'bundler'
require 'fileutils'
require 'json'
require 'open3'
require 'shellwords'
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
              'woods-mcp-start', '--checkout', '--await-index', '--client-root', subdirectory,
              '--client-identity', "main:#{git(@app, 'rev-parse', 'HEAD').strip}:main"])
  end

  describe 'the container entry, when the container mounts the main checkout' do
    # A stand-in for `docker compose exec` into a service that mounts the main
    # checkout: it runs the command after the service name in that checkout,
    # with the `-e` settings, and a client root the container cannot see
    # (the host path does not exist there).
    def stand_in_docker(mounted)
      stub_dir = File.join(@base, 'bin')
      FileUtils.mkdir_p(stub_dir)
      File.write(File.join(stub_dir, 'docker'), <<~SH)
        #!/bin/sh
        while [ "$1" != "bundle" ]; do
          if [ "$1" = "-e" ]; then shift; export "$1"; fi
          shift
        done
        cd #{Shellwords.escape(mounted)} || exit 1
        command=""
        for arg in "$@"; do
          if [ "$previous" = "--client-root" ]; then arg="/host-only$arg"; fi
          set -- "$@" "$arg"
          previous="$arg"
          shift
        done
        exec "$@"
      SH
      File.chmod(0o755, File.join(stub_dir, 'docker'))
      { 'PATH' => "#{stub_dir}:#{ENV.fetch('PATH')}" }
    end

    def refusal(entry, project, env)
      _out, errors, status = Open3.capture3(client_env(env.merge('CLAUDE_PROJECT_DIR' => project)),
                                            entry['command'], *entry['args'], stdin_data: '', chdir: @base,
                                                                              unsetenv_others: true)
      [status.exitstatus, errors]
    end

    before do
      @entry = application('--mcp-service', 'web')
      publish(@app)
      @worktree = File.join(@base, 'shop-topic')
      git(@app, 'worktree', 'add', '-q', '-b', 'topic', @worktree)
    end

    it 'serves a session in the main checkout with no map, with uncommitted changes and a detached HEAD' do
      File.write(File.join(@app, 'Gemfile'), "#{File.read(File.join(@app, 'Gemfile'))}# edited\n")
      [-> {}, -> { git(@app, 'checkout', '-q', '--detach') }].each do |prepare|
        prepare.call
        start(@entry, @base, stand_in_docker(@app).merge('CLAUDE_PROJECT_DIR' => @app))
        begin
          expect_found(lookup)
        ensure
          stop
        end
      end
    end

    it 'refuses a session in a linked worktree with no map, naming the map and the override' do
      code, errors = refusal(@entry, @worktree, stand_in_docker(@app))

      expect(code).to eq(1), errors
      expect(errors).to include('linked checkout on topic', 'WOODS_MCP_CLIENT_ROOT_MAP', '--allow-mismatch')
    end

    it 'refuses a session in a linked worktree with a map, as another checkout' do
      env = stand_in_docker(@app).merge('WOODS_MCP_CLIENT_ROOT_MAP' => "/host-only#{@base}=#{@base}")

      code, errors = refusal(@entry, @worktree, env)

      expect(code).to eq(1), errors
      expect(errors).to include("written for the checkout at #{@app}", "launched in #{@worktree}")
    end
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

  def agent_config(cwd, *arguments, env: {})
    output, status = Open3.capture2e(client_env(env), 'bundle', 'exec', 'woods-agent-config', *arguments,
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

  # The relative Compose entry runs `docker compose exec` with no -w, so the
  # server starts in the service's own working directory. Setup's preflight
  # runs the same invocation and refuses a directory that does not resolve
  # the requested application root.
  describe 'woods-agent-config setup for a Compose service' do
    def indexed_application(root)
      FileUtils.mkdir_p(root)
      git(@base, 'init', '-q', '-b', 'main', root)
      File.write(File.join(root, 'Gemfile'), "source 'https://rubygems.org'\ngem 'woods', path: #{repo.inspect}\n")
      lock_application(root)
      FileUtils.mkdir_p(File.join(root, 'lib'))
      File.write(File.join(root, 'lib', 'post.rb'), "class Post\n  def title; end\nend\n")
      Woods::GemMapper.new(root: root, output_dir: File.join(root, 'tmp', 'woods')).map!
    end

    def compose_setup(working_dir, container_root: @app, image: {})
      agent_config(@app, 'setup', '--plan', File.join(@base, 'compose.json'), '--mode', 'compose',
                   '--service', 'web', '--container-root', container_root,
                   env: stand_in_compose(working_dir).merge(image))
    end

    # An image whose BUNDLE_BIN is first on PATH: `bundle install` wrote a
    # `bundle` binstub there that fixes the Gemfile at its install-time path,
    # so Bundler resolves that application from any working directory.
    def bundle_binstub_image(gemfile)
      bin = File.join(@base, 'image-bin')
      FileUtils.mkdir_p(bin)
      bundle = ENV.fetch('PATH').split(File::PATH_SEPARATOR).map { |dir| File.join(dir, 'bundle') }
                  .find { |path| File.executable?(path) }
      File.write(File.join(bin, 'bundle'), <<~SH)
        #!/bin/sh
        : "${BUNDLE_GEMFILE:=#{gemfile}}"
        export BUNDLE_GEMFILE
        exec #{Shellwords.escape(bundle)} "$@"
      SH
      File.chmod(0o755, File.join(bin, 'bundle'))
      { 'STAND_IN_IMAGE_PATH' => bin }
    end

    before { indexed_application(@app) }

    it 'writes the relative entry when the service starts in the application root' do
      output, status = compose_setup(@app)

      expect(status.success?).to be(true), output
      expect(JSON.parse(output[/^\{.*\}\s*\z/m])).to include('entry_form' => 'relative')
    end

    it 'refuses a service that starts in another application, naming both directories' do
      other = File.join(@base, 'other')
      indexed_application(other)

      output, status = compose_setup(other)

      expect(status.success?).to be(false), output
      expect(output).to include("working directory, #{other}", "--container-root #{@app}", 'working_dir')
      expect(output).to include("preflight failed: The launch starts in #{other} and resolves the application at " \
                                "#{other}, not #{@app}\n")
    end

    it 'refuses a service in the application root whose bundle binstub resolves another application' do
      other = File.join(@base, 'other')
      indexed_application(other)

      output, status = compose_setup(@app, image: bundle_binstub_image(File.join(other, 'Gemfile')))

      expect(status.success?).to be(false), output
      expect(output).to include("preflight failed: The launch resolves the application at #{other}, not #{@app}\n")
      expect(output).not_to include('working directory,')
    end

    it 'refuses a service that starts where no Gemfile is found, naming both directories' do
      empty = File.join(@base, 'empty')
      FileUtils.mkdir_p(empty)

      output, status = compose_setup(empty)

      expect(status.success?).to be(false), output
      expect(output).to include("working directory, #{empty}", "--container-root #{@app}", 'working_dir')
    end

    it 'refuses a service outside any checkout even when a bundle binstub resolves the application there' do
      outside = File.join(@base, 'opt')
      FileUtils.mkdir_p(outside)

      output, status = compose_setup(outside, image: bundle_binstub_image(File.join(@app, 'Gemfile')))

      expect(status.success?).to be(false), output
      expect(output).to include("working directory, #{outside}", "--container-root #{@app}", 'working_dir')
      expect(output).to include("preflight failed: The launch starts in #{outside}, not #{@app}\n")
    end

    it 'accepts the application root reached through a symlink, and a container root with a trailing slash' do
      link = File.join(@base, 'shop-link')
      File.symlink(@app, link)

      output, status = compose_setup(link, container_root: "#{@app}/",
                                           image: bundle_binstub_image(File.join(@app, 'Gemfile')))

      expect(status.success?).to be(true), output
    end
  end

  # A stand-in for `docker compose exec`: it runs the command after the
  # service name with the -e settings, in the -w directory when one is
  # given, else in the service's working directory (STAND_IN_WORKING_DIR),
  # as a container that mounts the same paths would, with the image's own
  # PATH entries first (STAND_IN_IMAGE_PATH). Like Compose, it passes none of
  # the caller's Bundler activation into the container.
  # Real Compose is not run.
  def stand_in_compose(working_dir)
    stub_dir = File.join(@base, 'bin')
    FileUtils.mkdir_p(stub_dir)
    File.write(File.join(stub_dir, 'docker'), <<~SH)
      #!/bin/sh
      unset BUNDLE_GEMFILE BUNDLE_LOCKFILE BUNDLE_BIN_PATH BUNDLER_VERSION BUNDLER_SETUP RUBYOPT RUBYLIB
      shift
      if [ "$1" = "--project-directory" ]; then shift 2; fi
      shift
      dir="$STAND_IN_WORKING_DIR"
      if [ -n "$STAND_IN_IMAGE_PATH" ]; then PATH="$STAND_IN_IMAGE_PATH:$PATH"; fi
      while :; do
        case "$1" in -T) shift ;; -e) export "$2"; shift 2 ;; -w) dir="$2"; shift 2 ;; *) break ;; esac
      done
      shift
      cd "$dir" || exit 1
      exec "$@"
    SH
    File.chmod(0o755, File.join(stub_dir, 'docker'))
    { 'PATH' => "#{stub_dir}:#{ENV.fetch('PATH')}", 'STAND_IN_WORKING_DIR' => working_dir }
  end

  # The container entry carries no -w: the server starts in the service's
  # working directory, which must be the application, inside a mount of the
  # whole checkout. Bundler finds no Gemfile from the checkout root above it.
  it 'runs the container entry of an application below its checkout root in the service working directory' do
    checkout = File.join(@base, 'mono repo')
    git(@base, 'init', '-q', '-b', 'main', checkout)
    @app = File.join(checkout, 'apps', 'my web')
    FileUtils.mkdir_p(@app)
    File.write(File.join(@app, 'Gemfile'), "source 'https://rubygems.org'\ngem 'woods', path: #{repo.inspect}\n")
    generate(@app, '--mcp-config', '--mcp-service', 'web')
    entry = JSON.parse(File.read(File.join(@app, '.mcp.json'))).dig('mcpServers', 'woods')
    publish(@app)

    start(entry, checkout, stand_in_compose(@app))
    begin
      report = JSON.parse(request('tools/call', name: 'woods_status', arguments: { worktrees: 'none' })
                            .dig('result', 'content', 0, 'text'))
      expect(report.dig('server', 'index_dir')).to eq(File.join(@app, 'tmp', 'woods'))
    ensure
      stop
    end

    expect { start(entry, checkout, stand_in_compose(checkout)) }.to raise_error(/Could not locate Gemfile/)
  end
end
