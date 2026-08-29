# frozen_string_literal: true

require 'spec_helper'
require 'fileutils'
require 'mcp'
require 'net/http'
require 'nokogiri'
require 'open3'
require 'pathname'
require 'rubygems/package'
require 'socket'
require 'timeout'
require 'tmpdir'
require 'uri'

module PackagedGemSpec
  ROOT = File.expand_path('../..', __dir__)
  EXECUTABLES = %w[woods-mcp woods-mcp-start woods-console-mcp woods-console woods-mcp-http].freeze
  COMMUNITY_FILES = %w[
    LICENSE.txt
    README.md
    CHANGELOG.md
    CONTRIBUTING.md
    CODE_OF_CONDUCT.md
    SECURITY.md
  ].freeze
  # The audit ledger's own machinery — findings.json, surface-inventory
  # tooling — is deliberately excluded from the packaged gem (it has no
  # purpose outside this repo's own CI, which runs it straight from source).
  RELEASE_V2_MACHINERY = %r{\Alib/(tasks/release_v2\.rake|woods/release_v2/)}
  SEMANTIC_REOPEN_BOOTSTRAP = <<~'RUBY'
    require 'json'
    require 'woods'

    executable, index_dir, expected_cwd, source_root, gem_home, evidence_path = ARGV
    abort "unexpected cwd: #{Dir.pwd}" unless File.identical?(Dir.pwd, expected_cwd)
    source_entries = $LOAD_PATH.select do |entry|
      expanded = File.expand_path(entry)
      expanded == source_root || expanded.start_with?("#{source_root}/")
    end
    abort "source load path leaked: #{source_entries.join(', ')}" unless source_entries.empty?
    source_location = File.realpath(Woods.method(:configuration).source_location.fetch(0))
    gem_root = File.realpath(gem_home)
    abort "woods loaded outside installed gem: #{source_location}" unless source_location.start_with?("#{gem_root}/")
    artifact_path = File.realpath(index_dir)
    File.write(evidence_path, JSON.generate(
      pwd: File.realpath(Dir.pwd), load_path: $LOAD_PATH, source_location: source_location, artifact_path: artifact_path
    ))
    exec(executable, artifact_path)
  RUBY
end

RSpec.describe 'packaged gem' do
  before(:context) do
    @package_tmp = Dir.mktmpdir('woods-package-spec')
    @artifact = ENV['WOODS_GEM_PATH'] || File.join(@package_tmp, 'woods-2.0.0.gem')

    unless ENV['WOODS_GEM_PATH']
      output, status = Open3.capture2e(
        Gem.ruby, '-S', 'gem', 'build', '--strict', '--output', @artifact, 'woods.gemspec',
        chdir: PackagedGemSpec::ROOT
      )
      raise output unless status.success?
    end

    @package = Gem::Package.new(@artifact)
    @unpacked = File.join(@package_tmp, 'unpacked')
    FileUtils.mkdir_p(@unpacked)
    @package.extract_files(@unpacked)
  end

  after(:context) do
    FileUtils.remove_entry(@package_tmp) if @package_tmp && File.exist?(@package_tmp)
  end

  def package_files
    @package.spec.files.sort
  end

  def local_readme_targets
    # encoding: pinned so the multibyte README parses under a US-ASCII locale
    readme = File.read(File.join(@unpacked, 'README.md'), encoding: Encoding::UTF_8)
    markdown_targets = readme.scan(/\[[^\]]+\]\(([^)]+)\)/).flatten
    html_targets = Nokogiri::HTML.fragment(readme).css('[src], [href]').flat_map do |node|
      %w[src href].filter_map { |attribute| node[attribute] }
    end

    targets = (markdown_targets + html_targets).uniq
    targets.grep_v(%r{\A(?:[a-z][a-z0-9+.-]*:|#|//)}i)
           .map { |target| URI::DEFAULT_PARSER.unescape(target.sub(/[?#].*\z/, '')) }
           .reject(&:empty?)
  end

  def invalid_local_readme_targets
    package_root = File.expand_path(@unpacked)

    local_readme_targets.filter_map do |target|
      resolved = File.expand_path(target, package_root)
      within_package = resolved.start_with?("#{package_root}#{File::SEPARATOR}")
      next "#{target} (escapes package)" unless within_package
      next "#{target} (missing)" unless File.exist?(resolved)
    end
  end

  it 'contains every runtime file (excluding release_v2 audit machinery) and the exact five executables' do
    relative_lib_files = Dir[File.join(PackagedGemSpec::ROOT, 'lib/**/*')]
                         .select { |path| File.file?(path) }
                         .map { |path| Pathname(path).relative_path_from(Pathname(PackagedGemSpec::ROOT)).to_s }
    runtime_files = relative_lib_files.grep_v(PackagedGemSpec::RELEASE_V2_MACHINERY)

    expect(runtime_files).not_to be_empty
    expect(package_files).to include(*runtime_files)
    expect(@package.spec.executables).to contain_exactly(*PackagedGemSpec::EXECUTABLES)
    expected_executables = PackagedGemSpec::EXECUTABLES.map { |name| "exe/#{name}" }
    expect(package_files.grep(%r{\Aexe/})).to contain_exactly(*expected_executables)
  end

  it 'excludes the release_v2 audit machinery from the packaged gem' do
    expect(package_files.grep(PackagedGemSpec::RELEASE_V2_MACHINERY)).to be_empty
  end

  it 'excludes internal planning docs but keeps user-facing docs/*.md' do
    expect(package_files.grep(%r{\Adocs/}).grep_v(%r{\Adocs/[^/]+\.md\z})).to be_empty
    expect(package_files).to include('docs/README.md')
  end

  it 'contains the license and community files' do
    expect(package_files).to include(*PackagedGemSpec::COMMUNITY_FILES)
  end

  it 'keeps every local Markdown and HTML README target inside the unpacked gem' do
    expect(invalid_local_readme_targets).to be_empty
  end

  it 'rejects a local HTML target that escapes the unpacked gem' do
    readme_path = File.join(@unpacked, 'README.md')
    original = File.read(readme_path)
    File.write(readme_path, "#{original}\n<img src=\"../outside.png\">\n")

    expect(invalid_local_readme_targets).to include('../outside.png (escapes package)')
  ensure
    File.write(readme_path, original) if original
  end

  it 'uses immutable v2.0.0 source, changelog, and documentation metadata' do
    metadata = @package.spec.metadata

    expect(metadata.fetch('source_code_uri')).to eq('https://github.com/lost-in-the/woods/tree/v2.0.0')
    expect(metadata.fetch('changelog_uri')).to eq('https://github.com/lost-in-the/woods/blob/v2.0.0/CHANGELOG.md')
    expect(metadata.fetch('documentation_uri')).to eq('https://github.com/lost-in-the/woods/tree/v2.0.0/docs')
    expect(File.read(File.join(@unpacked, 'CHANGELOG.md'))).to include('## [2.0.0] - 2026-08-20')
  end

  # The every-PR tier (see the package-smoke job in ci.yml and the
  # :package_install filter in spec_helper.rb). The structural examples above
  # prove the artifact CONTAINS the right files; an inventory cannot catch a
  # packaging error that stops the installed gem from LOADING, so this group
  # installs the artifact into an isolated gem home and boots it. The full
  # installed-artifact suite stays release-gated under :packaged_gem below.
  describe 'installed artifact boot smoke', :package_install do
    before(:context) do
      @smoke_gem_home = File.join(@package_tmp, 'smoke-gem-home')
      output, status = Open3.capture2e(
        Gem.ruby, '-S', 'gem', 'install', '--local', '--ignore-dependencies', '--no-document',
        '--install-dir', @smoke_gem_home, @artifact
      )
      raise output unless status.success?
    end

    # Isolated GEM_HOME first, then the gems this checkout's bundle installed
    # (Bundler.bundle_path), then RubyGems' defaults. Runtime dependencies are
    # NOT vendored into the smoke gem home (the install above uses
    # --ignore-dependencies); they must resolve through GEM_PATH exactly as
    # they do for a real user who gem-installs woods alongside their deps.
    def smoke_env
      clean_env = ENV.to_h
      clean_env.each_key do |key|
        clean_env[key] = nil if key.start_with?('BUNDLE_') || %w[RUBYLIB RUBYOPT].include?(key)
      end
      bundle_path = defined?(Bundler) ? Bundler.bundle_path.to_s : nil
      gem_paths = [@smoke_gem_home, bundle_path, *Gem.path, *Gem.default_path].compact.uniq
      clean_env.merge(
        'GEM_HOME' => @smoke_gem_home,
        'GEM_PATH' => gem_paths.join(File::PATH_SEPARATOR),
        'OPENAI_API_KEY' => nil,
        'OLLAMA_BASE_URL' => 'http://127.0.0.1:1',
        'PATH' => [File.join(@smoke_gem_home, 'bin'), File.dirname(Gem.ruby), ENV.fetch('PATH')]
                  .join(File::PATH_SEPARATOR)
      )
    end

    it "loads 'woods' from the installed gem, with nothing from the checkout's lib on the load path" do
      script = <<~'RUBY'
        require 'woods'
        home = File.realpath(ENV.fetch('WOODS_SMOKE_GEM_HOME'))
        # The bundle path may legitimately live below the checkout (CI's
        # vendor/bundle), so a blanket "nothing under the repository root"
        # rule would reject the very GEM_PATH entries smoke_env adds. The
        # checkout's own lib is the only load-path entry that means "loaded
        # from source instead of the installed gem".
        lib = File.join(File.expand_path(ENV.fetch('WOODS_REPOSITORY_ROOT')), 'lib')
        leaked = $LOAD_PATH.select do |p|
          expanded = File.expand_path(p)
          expanded == lib || expanded.start_with?("#{lib}/")
        end
        abort "checkout lib leaked onto the load path: #{leaked.join(', ')}" unless leaked.empty?
        loaded = Gem.loaded_specs.fetch('woods').full_gem_path
        abort "woods loaded from #{loaded}, not the installed gem" unless loaded.start_with?(home)
        # loaded_specs names the gem; source_location proves the FILE actually
        # came from the isolated install, not a same-named copy elsewhere.
        defined_in = File.realpath(Woods.method(:configuration).source_location.fetch(0))
        abort "woods source loaded from #{defined_in}" unless defined_in.start_with?("#{home}/")
        puts 'ok'
      RUBY
      env = smoke_env.merge(
        'WOODS_REPOSITORY_ROOT' => PackagedGemSpec::ROOT,
        'WOODS_SMOKE_GEM_HOME' => @smoke_gem_home
      )
      stdout, stderr, status = Open3.capture3(env, Gem.ruby, '-e', script, chdir: @package_tmp)

      expect(status).to be_success, "require 'woods' failed outside the checkout:\n#{stderr}"
      expect(stdout).to eq("ok\n")
    end

    it 'boots the installed woods-mcp and answers an initialize request with protocol-pure stdout' do
      exe = File.join(@smoke_gem_home, 'bin', 'woods-mcp')
      fixture = File.join(PackagedGemSpec::ROOT, 'spec/fixtures/woods')
      request = JSON.generate(
        jsonrpc: '2.0', id: 1, method: 'initialize',
        params: {
          protocolVersion: '2026-07-28', capabilities: {},
          clientInfo: { name: 'pr-smoke', version: '1.0' }
        }
      )

      stdin, stdout, stderr, wait_thread = Open3.popen3(smoke_env, exe, fixture, chdir: @package_tmp)
      begin
        # The first stdout line must already be the JSON-RPC response: any
        # banner or warning interleaved here is a protocol violation, which is
        # why the assertion is JSON.parse on line one rather than a grep.
        response_line = nil
        Timeout.timeout(20) do
          stdin.puts(request)
          stdin.close
          response_line = stdout.gets
        end

        response = JSON.parse(response_line)
        expect(response).to include('jsonrpc' => '2.0', 'id' => 1)
        expect(response.fetch('result')).to include('serverInfo' => hash_including('name' => 'woods'))
        # The negotiated version is the server's choice for a raw handshake
        # (the official client's negotiation has its own contract spec); the
        # smoke asserts a version was negotiated, not which one.
        negotiated = response.fetch('result')['protocolVersion']
        expect(negotiated).to be_a(String)
        expect(negotiated).not_to be_empty

        # Purity, continued: after the response, nothing further on stdout —
        # EOF once the server exits on the closed stdin.
        remaining = nil
        Timeout.timeout(10) { remaining = stdout.read }
        expect(remaining).to eq('')

        wait_thread.join(5)
        expect(wait_thread).not_to be_alive
        expect(wait_thread.value).to be_success
        expect(stderr.read).not_to include('LoadError')
      ensure
        stdin.close unless stdin.closed?
        stdout.close unless stdout.closed?
        stderr.close unless stderr.closed?
        if wait_thread&.alive?
          # Cleanup only — an expectation here would mask the real failure.
          # The child can exit (and be reaped) between alive? and kill; the
          # same race reap_process handles in the release-gated group below.
          begin
            Process.kill('TERM', wait_thread.pid)
            wait_thread.join(5)
            Process.kill('KILL', wait_thread.pid) if wait_thread.alive?
            wait_thread.join(5)
          rescue Errno::ESRCH, Errno::ECHILD
            nil
          end
        end
      end
    end
  end

  describe 'clean installed artifact', :packaged_gem do
    before(:context) do
      @gem_home = File.join(@package_tmp, 'gem-home')
      output, status = Open3.capture2e(
        Gem.ruby, '-S', 'gem', 'install', '--local', '--ignore-dependencies', '--no-document',
        '--install-dir', @gem_home, @artifact
      )
      raise output unless status.success?
    end

    def installed_env
      clean_env = ENV.to_h
      clean_env.each_key do |key|
        clean_env[key] = nil if key.start_with?('BUNDLE_') || %w[RUBYLIB RUBYOPT].include?(key)
      end
      dependency_paths = ENV.fetch('WOODS_PACKAGE_GEM_PATH', '').split(File::PATH_SEPARATOR).reject(&:empty?)
      clean_env.merge(
        'BUNDLE_IGNORE_CONFIG' => '1',
        'GEM_HOME' => @gem_home,
        'GEM_PATH' => ([@gem_home] + dependency_paths + Gem.path + Gem.default_path).uniq.join(File::PATH_SEPARATOR),
        'OPENAI_API_KEY' => nil,
        'OLLAMA_BASE_URL' => 'http://127.0.0.1:1',
        'PACKAGE_GEM_HOME' => @gem_home,
        'PATH' => [File.join(@gem_home, 'bin'), File.dirname(Gem.ruby), ENV.fetch('PATH')]
                  .join(File::PATH_SEPARATOR)
      )
    end

    def run_installed(*command, chdir: @package_tmp)
      Open3.capture3(installed_env, *command, chdir: chdir)
    end

    def build_installed_preset_artifact(preset, index_dir) # rubocop:disable Metrics/MethodLength
      FileUtils.cp_r(File.join(PackagedGemSpec::ROOT, 'spec/fixtures/woods', '.'), index_dir)
      script = <<~'RUBY'
        require 'woods'
        require 'woods/builder'
        require 'woods/index_artifact'
        require 'woods/resolved_config'
        require 'woods/storage/snapshotter'

        preset, output_dir = ARGV
        config = Woods::Builder.preset_config(preset.to_sym)
        config.output_dir = output_dir
        config.embedding_provider = :fake
        config.embedding_options = { model: "#{preset}-installed", dimensions: 8 }
        builder = Woods::Builder.new(config)
        provider = builder.build_embedding_provider
        vectors = builder.build_vector_store(dimensions: 8)
        metadata = builder.build_metadata_store
        vectors.store('User', provider.embed('User model account'), type: 'model', identifier: 'User')
        metadata.store('User', type: 'model', identifier: 'User', source_code: 'class User; end')
        artifact = Woods::IndexArtifact.new(output_dir)
        resolved = Woods::ResolvedConfig.from_configuration(config, provider: provider)
        dump = artifact.new_dump_dir
        Woods::Storage::Snapshotter::Vector.dump(vectors, artifact, dump, resolved_config: resolved)
        if config.metadata_store == :in_memory
          Woods::Storage::Snapshotter::Metadata.dump(metadata, artifact, dump, resolved_config: resolved)
        end
        artifact.promote(dump)
        artifact.write_config(resolved)
      RUBY
      stdout, stderr, status = run_installed('ruby', '-e', script, preset.to_s, index_dir)
      expect_success(['ruby', '-e', 'build installed preset artifact'], stdout, stderr, status)
    end

    def installed_reopen_env(index_dir, isolated_cwd, evidence_path)
      installed_env.merge(
        'WOODS_TEST_CWD' => isolated_cwd,
        'WOODS_TEST_RUBY' => Gem.ruby,
        'WOODS_TEST_BOOTSTRAP' => PackagedGemSpec::SEMANTIC_REOPEN_BOOTSTRAP,
        'WOODS_TEST_EXECUTABLE' => File.join(@gem_home, 'bin/woods-mcp'),
        'WOODS_TEST_INDEX' => File.expand_path(index_dir),
        'WOODS_TEST_SOURCE_ROOT' => PackagedGemSpec::ROOT,
        'WOODS_TEST_GEM_HOME' => @gem_home,
        'WOODS_TEST_EVIDENCE' => evidence_path
      )
    end

    def installed_reopen_transport(env)
      MCP::Client::Stdio.new(
        command: '/bin/sh',
        args: ['-c', <<~'SH'],
          cd "$WOODS_TEST_CWD" && exec "$WOODS_TEST_RUBY" -e "$WOODS_TEST_BOOTSTRAP" \
            "$WOODS_TEST_EXECUTABLE" "$WOODS_TEST_INDEX" "$WOODS_TEST_CWD" \
            "$WOODS_TEST_SOURCE_ROOT" "$WOODS_TEST_GEM_HOME" "$WOODS_TEST_EVIDENCE"
        SH
        env: env,
        read_timeout: 10
      )
    end

    def installed_semantic_result(transport)
      client = MCP::Client.new(transport: transport)
      client.connect(client_info: { name: 'preset-reopen', version: '1.0' },
                     protocol_version: '2026-07-28', mode: :modern)
      client.call_tool(name: 'codebase_retrieve', arguments: { query: 'User model' })
    end

    def assert_installed_reopen_evidence(evidence_path, isolated_cwd, index_dir)
      evidence = JSON.parse(File.read(evidence_path))
      expect(evidence.fetch('pwd')).to eq(File.realpath(isolated_cwd))
      expect(evidence.fetch('load_path')).not_to include(PackagedGemSpec::ROOT, File.join(PackagedGemSpec::ROOT, 'lib'))
      expect(evidence.fetch('source_location')).to start_with(File.realpath(@gem_home))
      expect(evidence.fetch('artifact_path')).to eq(File.realpath(index_dir))
    end

    def assert_installed_semantic_reopen(index_dir)
      isolated_cwd = Dir.mktmpdir('woods-installed-cwd', @package_tmp)
      evidence_path = File.join(isolated_cwd, 'boot-evidence.json')
      transport = installed_reopen_transport(installed_reopen_env(index_dir, isolated_cwd, evidence_path))
      result = installed_semantic_result(transport)
      expect(result.dig('result', 'isError')).to be(false)
      expect(result.dig('result', 'structuredContent', 'text')).to include('User')
      assert_installed_reopen_evidence(evidence_path, isolated_cwd, index_dir)
    ensure
      transport&.close
    end

    def expect_success(command, stdout, stderr, status)
      expect(status).to be_success, <<~MESSAGE
        #{command.join(' ')} failed with #{status.exitstatus}
        stdout:
        #{stdout}
        stderr:
        #{stderr}
      MESSAGE
    end

    def assert_installed_protocol(client)
      discovery = client.connect(
        client_info: { name: 'installed-woods-contract', version: '1.0' },
        protocol_version: '2026-07-28',
        mode: :modern
      )
      expect(discovery.dig('_meta', 'io.modelcontextprotocol/serverInfo', 'name')).to eq('woods')
      expect(client.tools.map(&:name)).to include('lookup', 'woods_status')
      result = client.call_tool(name: 'lookup', arguments: { identifier: 'Post' })
      expect(result.dig('result', 'isError')).to be(false)
      expect(result.dig('result', 'structuredContent', 'text')).to include('Post')
    end

    def free_port
      server = TCPServer.new('127.0.0.1', 0)
      server.local_address.ip_port
    ensure
      server&.close
    end

    def wait_for_http(base, wait_thread, output)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 30
      loop do
        raise "installed HTTP server exited:\n#{output.read}" unless wait_thread.alive?

        begin
          Net::HTTP.start(base.host, base.port, open_timeout: 1, read_timeout: 1) { |http| http.head('/') }
          return
        rescue StandardError
          if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
            raise "installed HTTP server never bound to #{base}"
          end

          sleep 0.1
        end
      end
    end

    def reap_process(wait_thread)
      return unless wait_thread

      Process.kill('TERM', wait_thread.pid) if wait_thread.alive?
      wait_thread.join(5)
      if wait_thread.alive?
        Process.kill('KILL', wait_thread.pid)
        wait_thread.join(5)
      end
      expect(wait_thread).not_to be_alive
    rescue Errno::ESRCH, Errno::ECHILD
      nil
    end

    def write_dummy_app(app) # rubocop:disable Metrics/MethodLength
      files = {
        'Gemfile' => <<~GEMFILE,
          source 'https://rubygems.org'

          gem 'actionmailer', require: false
          gem 'actionpack', require: false
          gem 'activerecord', require: false
          gem 'railties', require: false
          gem 'sqlite3', require: false
          gem 'woods', '= 2.0.0', require: false
        GEMFILE
        'Rakefile' => <<~RUBY,
          require_relative 'config/application'
          Rails.application.load_tasks
        RUBY
        'bin/rails' => <<~RUBY,
          #!/usr/bin/env ruby
          APP_PATH = File.expand_path('../config/application', __dir__)
          require_relative '../config/boot'
          require 'rails/commands'
        RUBY
        'config/boot.rb' => <<~RUBY,
          ENV['BUNDLE_GEMFILE'] ||= File.expand_path('../Gemfile', __dir__)
          require 'logger'
          require 'bundler/setup'
        RUBY
        'config/application.rb' => <<~RUBY,
          require_relative 'boot'
          require 'rails'
          require 'active_record/railtie'
          require 'action_controller/railtie'
          require 'action_mailer/railtie'
          require 'woods'

          module PackageDummy
            class Application < Rails::Application
              config.eager_load = false
              config.secret_key_base = 'package-test-secret'
            end
          end
        RUBY
        'config/environment.rb' => <<~RUBY,
          require_relative 'application'
          Rails.application.initialize!
        RUBY
        'config/routes.rb' => <<~RUBY,
          Rails.application.routes.draw { resources :posts, only: :index }
        RUBY
        'config/database.yml' => <<~YAML,
          development:
            adapter: sqlite3
            database: <%= File.expand_path('../package.sqlite3', __dir__) %>
        YAML
        'app/models/application_record.rb' => <<~RUBY,
          class ApplicationRecord < ActiveRecord::Base
            self.abstract_class = true
          end
        RUBY
        'app/models/post.rb' => <<~RUBY,
          class Post < ApplicationRecord
            validates :title, presence: true
          end
        RUBY
        'db/migrate/20260819000000_create_posts.rb' => <<~RUBY
          class CreatePosts < ActiveRecord::Migration[6.0]
            def change
              create_table(:posts) { |table| table.string :title }
            end
          end
        RUBY
      }

      files.each do |relative_path, contents|
        path = File.join(app, relative_path)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, contents)
      end
      FileUtils.chmod('+x', File.join(app, 'bin/rails'))
    end # rubocop:enable Metrics/MethodLength

    it 'requires woods without the repository on the load path' do
      script = <<~RUBY
        require 'woods'
        root = File.expand_path(ENV.fetch('WOODS_REPOSITORY_ROOT'))
        abort "repository leaked onto $LOAD_PATH" if $LOAD_PATH.any? { |path| File.expand_path(path).start_with?(root) }
        installed_root = File.realpath(ENV.fetch('PACKAGE_GEM_HOME'))
        loaded_root = File.realpath(Gem.loaded_specs.fetch('woods').full_gem_path)
        abort "wrong installed gem" unless loaded_root.start_with?(installed_root)
        puts Woods::VERSION
      RUBY
      env = installed_env.merge('WOODS_REPOSITORY_ROOT' => PackagedGemSpec::ROOT)
      stdout, stderr, status = Open3.capture3(env, 'ruby', '-e', script, chdir: @package_tmp)

      expect_success(['ruby', '-e', 'require woods'], stdout, stderr, status)
      expect(stdout).to eq("2.0.0\n")
    end

    it 'loads all five installed executables to their safe startup boundaries' do
      cases = {
        'woods-mcp' => ['/definitely/missing/woods-index'],
        'woods-mcp-start' => [],
        'woods-console-mcp' => [],
        'woods-console' => [],
        'woods-mcp-http' => ['/definitely/missing/woods-index']
      }

      cases.each do |name, arguments|
        _stdout, stderr, status = run_installed(File.join(@gem_home, 'bin', name), *arguments)

        expect(status).not_to be_success
        expect(stderr).not_to include('LoadError', "#{name} failed while loading:\n#{stderr}")
        expect(stderr).not_to match(/from .+\.rb:\d+:in/)
      end
    end

    it 'starts the Index MCP server through the installed wrapper' do
      index_dir = File.join(@package_tmp, 'index')
      FileUtils.cp_r(File.join(PackagedGemSpec::ROOT, 'spec/fixtures/woods'), index_dir)
      stdin, stdout, stderr, wait_thread = Open3.popen3(
        installed_env,
        File.join(@gem_home, 'bin/woods-mcp-start'),
        index_dir,
        chdir: @package_tmp
      )
      sleep 2
      booted = wait_thread.alive?
      Process.kill('TERM', wait_thread.pid) if wait_thread.alive?
      wait_thread.join(5)
      error_output = stderr.read
      stdin.close
      stdout.close
      stderr.close

      expect(booted).to be(true), error_output
      expect(error_output).not_to include('LoadError')
      expect(error_output).not_to match(/from .+\.rb:\d+:in/)
    end

    it 'drives the installed woods-mcp executable with the official Ruby client' do
      transport = MCP::Client::Stdio.new(
        command: File.join(@gem_home, 'bin/woods-mcp'),
        args: [File.join(PackagedGemSpec::ROOT, 'spec/fixtures/woods')],
        env: installed_env,
        read_timeout: 10
      )
      assert_installed_protocol(MCP::Client.new(transport: transport))
      wait_thread = transport.instance_variable_get(:@wait_thread)
    ensure
      transport&.close
      expect(wait_thread).not_to be_alive if wait_thread
    end

    %i[local shared_filesystem].each do |preset|
      it "reopens the #{preset} preset through installed woods-mcp from a clean cwd" do
        index_dir = File.join(@package_tmp, "#{preset}-index")
        FileUtils.mkdir_p(index_dir)
        build_installed_preset_artifact(preset, index_dir)

        assert_installed_semantic_reopen(index_dir)
      end
    end

    { pgvector: 'WOODS_PG_URL', qdrant: 'WOODS_QDRANT_URL' }.each do |adapter, setting|
      it "fails installed woods-mcp actionably when #{adapter} lacks #{setting}" do
        index_dir = File.join(@package_tmp, "missing-#{adapter}")
        FileUtils.mkdir_p(index_dir)
        FileUtils.cp(
          File.join(PackagedGemSpec::ROOT, 'spec/fixtures/woods/manifest.json'),
          File.join(index_dir, 'manifest.json')
        )
        snapshot = {
          schema_version: 1, gem_version: '2.0.0', created_at: Time.now.utc.iso8601,
          embedding_provider: { class: 'Woods::Embedding::Provider::Fake', model: 'installed', dimension: 8 },
          stores: { vector_store: adapter, metadata_store: 'in_memory', graph_store: 'in_memory' },
          store_options: {
            vector_store: adapter == :qdrant ? { collection: 'woods', dimensions: 8 } : { dimensions: 8 }
          }
        }
        File.write(File.join(index_dir, 'woods.json'), JSON.pretty_generate(snapshot))

        _stdout, stderr, status = run_installed(File.join(@gem_home, 'bin/woods-mcp'), index_dir)

        expect(status).not_to be_success
        expect(stderr).to include(setting)
        expect(stderr).not_to include('NoMethodError', 'ArgumentError')
      end
    end

    it 'drives the installed woods-mcp-http executable with the official Ruby client over a real socket' do
      port = free_port
      base = URI("http://127.0.0.1:#{port}/")
      stdin, output, wait_thread = Open3.popen2e(
        installed_env.merge('PORT' => port.to_s, 'HOST' => '127.0.0.1', 'WOODS_MCP_HTTP_STATELESS' => '1'),
        File.join(@gem_home, 'bin/woods-mcp-http'),
        File.join(PackagedGemSpec::ROOT, 'spec/fixtures/woods'),
        chdir: @package_tmp
      )
      wait_for_http(base, wait_thread, output)
      transport = MCP::Client::HTTP.new(url: base.to_s)
      assert_installed_protocol(MCP::Client.new(transport: transport))
    ensure
      transport&.close
      reap_process(wait_thread)
      stdin&.close unless stdin&.closed?
      output&.close unless output&.closed?
    end

    it 'runs both generators, loads rake tasks, and extracts a dummy Rails app' do
      app = File.join(@package_tmp, 'dummy-app')
      write_dummy_app(app)
      commands = [
        %w[bundle install --local],
        %w[bin/rails generate woods:install],
        %w[bin/rails db:migrate],
        %w[bin/rails generate woods:pgvector],
        %w[bundle exec rake -T woods],
        %w[bin/rails woods:extract]
      ]
      results = commands.to_h do |app_command|
        stdout, stderr, status = run_installed(*app_command, chdir: app)
        expect_success(app_command, stdout, stderr, status)
        [app_command.join(' '), stdout]
      end

      expect(results.fetch('bundle exec rake -T woods')).to include('woods:extract')
      woods_migration = Dir[File.join(app, 'db/migrate/*_create_woods_tables.rb')].fetch(0)
      pgvector_migration = Dir[File.join(app, 'db/migrate/*_add_pgvector_to_woods.rb')].fetch(0)
      stdout, stderr, status = run_installed(
        'bundle', 'exec', 'ruby', '-rlogger', '-ractive_record', '-e',
        'print ActiveRecord::Migration.current_version', chdir: app
      )
      expect_success(['ActiveRecord::Migration.current_version'], stdout, stderr, status)
      # The migration templates open with a documentation comment, so assert
      # the version declaration anywhere in the generated file, not on line one.
      migration_version = "ActiveRecord::Migration[#{stdout}]"
      expect(File.read(woods_migration)).to include(migration_version)
      expect(File.read(pgvector_migration)).to include(migration_version)
      # Extraction publishes each generation under payloads/gen-<N>/, so the
      # model payloads live below the generation directory, not the output root.
      expect(Dir[File.join(app, 'tmp/woods/payloads/gen-*/models/Post_*.json')]).not_to be_empty
    end
  end
end
