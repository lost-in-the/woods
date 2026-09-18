# frozen_string_literal: true

# Self-contained: the trusted release workflow runs this with --options /dev/null,
# without spec_helper or a source lib path. All product code runs in fresh children.
require 'rspec'
require 'fileutils'
require 'digest'
require 'json'
require 'open3'
require 'rubygems/package'
require 'tmpdir'
require 'timeout'

RSpec.describe 'Installed maintenance package', :maintenance_package do
  before(:context) do
    @artifact = File.expand_path(ENV.fetch('WOODS_GEM_PATH'))
    @package = Gem::Package.new(@artifact)
    @version = @package.spec.version.to_s
    @expected_mcp = ENV.fetch('WOODS_EXPECT_MCP_VERSION', '')
    @root = Dir.mktmpdir('woods-maintenance-package')
    @gem_home = File.join(@root, 'gems')
    @env = ENV.keys.grep(/\ABUNDLE/).to_h { |key| [key, nil] }.merge(
      'GEM_HOME' => @gem_home, 'GEM_PATH' => ([@gem_home] + Gem.path).join(File::PATH_SEPARATOR),
      'RUBYOPT' => nil, 'RUBYLIB' => nil, 'WOODS_NO_UPDATE_CHECK' => '1', 'RAILS_ENV' => 'test'
    )
    result, status = Open3.capture2e(@env, Gem.ruby, '-S', 'gem', 'install', '--local', '--ignore-dependencies',
                                     '--no-document', @artifact, chdir: @root)
    raise result unless status.success?

    @installed = File.join(@gem_home, 'gems', "woods-#{@version}")
    prepare_installed_bundle
  end

  after(:context) { FileUtils.remove_entry(@root) if @root && File.directory?(@root) }

  # Match supported `bundle exec` launchers. Bare RubyGems may activate its
  # newest default JSON gem before resolving Woods' declared JSON constraint.
  def prepare_installed_bundle
    gemfile = File.join(@root, 'Gemfile')
    File.write(gemfile, <<~GEMFILE)
      source 'https://rubygems.org'
      gem 'woods', '= #{@version}'
      gem 'rails'
      gem 'sqlite3'
      gem 'rspec'
      # Explicitly prove the minimum SDK even with newer versions installed.
      #{"gem 'mcp', '= #{@expected_mcp}'" unless @expected_mcp.empty?}
    GEMFILE
    @env['BUNDLE_GEMFILE'] = gemfile
    @env['BUNDLE_APP_CONFIG'] = File.join(@root, '.bundle')
    result, status = Open3.capture2e(@env, Gem.ruby, '-S', 'bundle', 'lock', '--local',
                                     chdir: @root)
    raise result unless status.success?
  end

  def run_child(*args, input: '', timeout: 60)
    result = nil
    Open3.popen3(@env, Gem.ruby, '-rbundler/setup', *args,
                 chdir: @root, pgroup: true) do |stdin, stdout, stderr, waiter|
      readers = [Thread.new { stdout.read }, Thread.new { stderr.read }]
      begin
        Timeout.timeout(timeout) do
          stdin.write(input)
          stdin.close
          result = [readers.map(&:value), waiter.value]
        end
      ensure
        begin
          Process.kill('KILL', -waiter.pid)
        rescue Errno::ESRCH
          # The child group already exited.
        end
        waiter.join(5)
        readers.each { |thread| thread.kill if thread.alive? }
      end
    end
    result
  end

  def assert_installed_source
    <<~RUBY
      spec = Gem.loaded_specs.fetch('woods')
      abort 'wrong activated gem' unless spec.full_gem_path == #{@installed.inspect}
      features = $LOADED_FEATURES.select { |path| path.include?('/woods/') || path.end_with?('/woods.rb') }
      abort 'source implementation leaked' unless !features.empty? && features.all? { |path| path.start_with?(spec.full_gem_path + '/') }
      mcp = Gem.loaded_specs.fetch('mcp').version
      abort 'unsafe MCP dependency' unless Gem::Requirement.new('>= 0.23.0', '< 1.0').satisfied_by?(mcp)
      expected = #{@expected_mcp.inspect}
      abort 'wrong exact MCP floor' unless expected.empty? || mcp.to_s == expected
      json = Gem.loaded_specs.fetch('json').version
      abort 'incompatible JSON dependency' unless Gem::Requirement.new('>= 2.19.9', '< 3').satisfied_by?(json)
      puts "JSON_ARTIFACT_VERSION=\#{json}"
      puts "MCP_ARTIFACT_VERSION=\#{mcp}"
      puts 'INSTALLED_WOODS_PROVENANCE_OK'
    RUBY
  end

  it 'contains the five v1 executables and excludes maintenance tooling' do
    expect(@package.spec.executables).to contain_exactly('woods-mcp', 'woods-mcp-start', 'woods-console-mcp',
                                                         'woods-console', 'woods-mcp-http')
    expect(@package.spec.files).not_to include('lib/tasks/release.rake', 'lib/woods/release.rb')
    expect(@package.spec.files.grep(%r{\Alib/woods/release/})).to be_empty
    mcp = @package.spec.dependencies.find { |dependency| dependency.name == 'mcp' }.requirement
    expect(mcp).to be_satisfied_by(Gem::Version.new('0.23.0'))
    expect(mcp).not_to be_satisfied_by(Gem::Version.new('0.9.2'))
    expect(mcp).not_to be_satisfied_by(Gem::Version.new('1.0.0'))
    unless @version.end_with?('.alpha')
      expect(@package.spec.metadata.fetch('source_code_uri')).to end_with("/v#{@version}")
    end
  end

  it 'constrains serialization and framework dependencies to the supported major lines' do
    { 'json' => ['2.19.9', '3.0.0'], 'msgpack' => ['1.5.0', '2.0.0'],
      'railties' => ['6.0.0', '9.0.0'] }.each do |name, (floor, next_major)|
      dependency = @package.spec.dependencies.find { |item| item.name == name }
      expect(dependency).not_to be_nil
      expect(dependency.requirement).to be_satisfied_by(Gem::Version.new(floor))
      expect(dependency.requirement).not_to be_satisfied_by(Gem::Version.new(next_major))
    end
  end

  it 'loads the installed artifact with its declared legacy MCP dependency' do
    source = <<~RUBY
      gem 'mcp', '= #{@expected_mcp}' unless #{@expected_mcp.empty?}
      gem 'woods', '= #{@version}'
      require 'woods'
      require 'woods/mcp/server'
      abort 'wrong MCP major' unless Gem.loaded_specs.fetch('mcp').version < Gem::Version.new('1.0')
      #{assert_installed_source}
    RUBY
    output, status = run_child('-e', source)
    expect(status).to be_success, output.join("\n")
    expect(output.first).to include('INSTALLED_WOODS_PROVENANCE_OK')
    RSpec.configuration.reporter.message(output.first.lines.grep(/(?:MCP|JSON)_ARTIFACT_VERSION=/).join)
  end

  it 'serves initialization, lookup and structured errors through the installed stdio executable' do
    index = File.join(@root, 'index')
    FileUtils.mkdir_p(File.join(index, 'models'))
    File.write(File.join(index, 'manifest.json'), JSON.generate(total_units: 1, counts: { models: 1 }))
    File.write(File.join(index, 'dependency_graph.json'),
               JSON.generate(nodes: {}, edges: {}, reverse: {}, file_map: {}))
    File.write(File.join(index, 'models', '_index.json'), JSON.generate([{ identifier: 'PackageNote', type: 'model' }]))
    filename = "PackageNote_#{Digest::SHA256.hexdigest('PackageNote')[0, 8]}.json"
    File.write(File.join(index, 'models', filename), JSON.generate(identifier: 'PackageNote', type: 'model',
                                                                   source_code: 'class PackageNote; end'))
    requests = [
      { jsonrpc: '2.0', id: 1, method: 'initialize',
        params: { protocolVersion: '2025-03-26', capabilities: {},
                  clientInfo: { name: 'maintenance-test', version: '1' } } },
      { jsonrpc: '2.0', method: 'notifications/initialized' },
      { jsonrpc: '2.0', id: 2, method: 'tools/call',
        params: { name: 'lookup', arguments: { identifier: 'PackageNote' } } },
      { jsonrpc: '2.0', id: 3, method: 'tools/call', params: { name: 'lookup', arguments: { identifier: 'Missing' } } }
    ]
    bootstrap = <<~RUBY
      gem 'mcp', '= #{@expected_mcp}' unless #{@expected_mcp.empty?}
      gem 'woods', '= #{@version}'
      load Gem.bin_path('woods', 'woods-mcp')
    RUBY
    input = requests.map { |item| "#{JSON.generate(item)}\n" }.join
    output, status = run_child('-e', bootstrap, index, input: input)
    expect(status).to be_success, output.join("\n")
    responses = output.first.lines.map { |line| JSON.parse(line) }.to_h { |response| [response['id'], response] }
    expect(responses.dig(1, 'result', 'serverInfo', 'version')).to eq(@version)
    expect(responses.dig(2, 'result', 'isError')).to be(false), output.join("\n")
    expect(responses.dig(2, 'result', 'content').to_s).to include('PackageNote')
    expect(responses.dig(3, 'result', 'isError')).to be true
    expect(responses.dig(3, 'result', '_meta', 'error_code')).to eq('not_found')
  end

  it 'passes all nine real encrypted credential regressions using only installed Woods code' do
    fixture = File.expand_path('console_credential_rotation_spec.rb', __dir__)
    FileUtils.cp(fixture, File.join(@root, 'rotation_spec.rb'))
    File.write(File.join(@root, 'spec_helper.rb'), <<~RUBY)
      require 'logger'
      require 'rspec'
      require 'active_support/core_ext/hash/keys'
      RSpec.configure { |config| config.fail_if_no_examples = true }
    RUBY
    source = <<~RUBY
      gem 'mcp', '= #{@expected_mcp}' unless #{@expected_mcp.empty?}
      gem 'woods', '= #{@version}'
      require 'rspec/core'
      $LOAD_PATH.unshift(Dir.pwd)
      status = RSpec::Core::Runner.run(['--options', '/dev/null', './rotation_spec.rb', '--seed', '47193'])
      abort 'wrong credential scenario count' unless RSpec.world.example_count == 9
      #{assert_installed_source}
      exit status
    RUBY
    output, status = run_child('-e', source)
    expect(status).to be_success, output.join("\n")
    expect(output.first).to include('9 examples, 0 failures', 'INSTALLED_WOODS_PROVENANCE_OK')
    RSpec.configuration.reporter.message(output.first.lines.grep(/(?:MCP|JSON)_ARTIFACT_VERSION=/).join)
  end
end
