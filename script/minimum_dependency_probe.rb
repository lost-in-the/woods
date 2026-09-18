# frozen_string_literal: true

# Executed only by the isolated installed-artifact compatibility harness.
require 'bundler'
require 'json'
require 'tmpdir'
require 'fileutils'
require 'logger'
require 'rails'
require 'woods'
require 'woods/mcp/bootstrapper'
require 'woods/mcp/server'
require 'woods/storage/snapshotter/metadata'

module MinimumDependencyProbe # rubocop:disable Metrics/ModuleLength
  module_function

  def assert(condition, message)
    raise message unless condition

    puts "PASS: #{message}"
  end

  def installed_versions # rubocop:disable Metrics/AbcSize
    expected = ENV.fetch('WOODS_MINIMUM_INSTALLED')
    assert(Gem.loaded_specs.fetch('woods').full_gem_path == expected, 'Woods loaded from installed candidate gem')
    pins = Bundler.definition.dependencies.reject { |dependency| dependency.name == 'woods' }
    pins.each do |dependency|
      version = Gem.loaded_specs.fetch(dependency.name).version
      assert(dependency.requirement.requirements == [['=', version]],
             "exact runtime floor #{dependency.name}=#{version}")
    end
    resolved = Bundler.load.specs.sort_by(&:name).map do |spec|
      { name: spec.name, version: spec.version.to_s, platform: spec.platform.to_s,
        required_ruby: spec.required_ruby_version.to_s }
    end
    report = { ruby: RUBY_DESCRIPTION, bundler: Bundler::VERSION,
               direct_floors: pins.to_h { |dep| [dep.name, dep.requirement.to_s] }, gems: resolved }
    File.write(File.join(ENV.fetch('WOODS_MINIMUM_EVIDENCE'), 'resolved.json'), JSON.pretty_generate(report))
  end

  def index_contract(root) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
    unit = Woods::ExtractedUnit.new(type: :model, identifier: 'Invoice', file_path: 'app/models/invoice.rb')
    unit.source_code = 'class Invoice; def refund; :refunded; end; end'
    directory = File.join(root, 'models')
    FileUtils.mkdir_p(directory)
    filename = Object.new.extend(Woods::FilenameUtils).collision_safe_filename(unit.identifier)
    File.write(File.join(directory, filename), JSON.generate(unit.to_h))
    File.write(File.join(directory, '_index.json'), JSON.generate([{ identifier: 'Invoice' }]))
    File.write(File.join(root, 'manifest.json'), JSON.generate(counts: { models: 1 }))
    Woods.configuration.retrieval_mode = :lexical
    retriever, state = Woods::MCP::Bootstrapper.build_retriever(index_dir: root)
    assert(state.status == :hydrated, 'extract-only lexical bootstrap without provider/vector artifacts')
    result = retriever.retrieve('refund', budget: 1000)
    assert(result.sources.any? { |source| source[:identifier] == 'Invoice' && source[:type] == 'model' },
           'lexical retrieval preserves typed identity')
    server = Woods::MCP::Server.build(index_dir: root, retriever: retriever)
    protocol_contract(server)
    parser = Woods::Ast::Parser.new
    assert(parser.prism_available? && parser.parse(unit.source_code).find_all(:def).first.method_name == 'refund',
           'Prism parses method through Woods AST adapter')
    store = Woods::Storage::MetadataStore::InMemory.new
    store.store('Invoice', { 'type' => 'model', 'unicode' => 'café', 'count' => 3 })
    artifact = Woods::IndexArtifact.new(root)
    artifact.dumps_root.mkpath
    Woods::Storage::Snapshotter::Metadata.dump(store, artifact, artifact.dumps_root)
    restored = Woods::Storage::Snapshotter::Metadata.load_dump_dir(artifact.dumps_root, required: true)
    assert(restored.find('Invoice') == store.find('Invoice'), 'MessagePack metadata snapshot round trip')
  end

  def protocol_contract(server)
    initialize_request = {
      jsonrpc: '2.0', id: 1, method: 'initialize',
      params: { protocolVersion: '2026-07-28', capabilities: {},
                clientInfo: { name: 'minimum-runtime-probe', version: '1' } }
    }
    response = JSON.parse(server.handle_json(JSON.generate(initialize_request)))
    assert(response.dig('result', 'protocolVersion').is_a?(String), 'SDK JSON-RPC initialization negotiates protocol')
    listing = JSON.parse(server.handle_json(JSON.generate(jsonrpc: '2.0', id: 2, method: 'tools/list')))
    assert(listing.dig('result', 'tools').any? { |tool| tool['name'] == 'lookup' }, 'SDK lists registered lookup tool')
    request = { jsonrpc: '2.0', id: 3, method: 'tools/call',
                params: { name: 'lookup', arguments: { identifier: 'Invoice' } } }
    response = JSON.parse(server.handle_json(JSON.generate(request)))
    assert(response.dig('result', 'content').to_s.include?('Invoice') && !response.dig('result', 'isError'),
           'SDK JSON-RPC lookup dispatch over installed published-unit reader')
  end

  def rails_contract(root) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
    puts 'Rails fixture: API-only, static serving disabled; full Rails 6.0.0/Ruby 3 compatibility is not claimed'
    app = Class.new(Rails::Application)
    app.config.root = root
    app.config.eager_load = false
    # Rails 6.0.0 itself predates Ruby 3 keyword forwarding in Static/sessions.
    # This API-style host exercises Woods without those unrelated middlewares.
    app.config.api_only = true
    app.config.public_file_server.enabled = false
    app.config.logger = Logger.new(File::NULL)
    app.config.secret_key_base = 'minimum-dependency-probe' * 4
    app.initialize!
    app.load_tasks
    assert(Rake::Task.task_defined?('woods:extract'),
           'real Rails floor boots Woods railtie and registers extraction task')
    endpoint = ->(_env) { [200, {}, ['next app']] }
    disabled = ActionDispatch::MiddlewareStack.new
    disabled.use(Woods::Console::RackMiddleware, path: '/mcp/console')
    assert(disabled.build(endpoint).call('PATH_INFO' => '/mcp/console').first == 200, 'disabled Console passes through')
    token = 'a' * 64
    stack = ActionDispatch::MiddlewareStack.new
    stack.use(Woods::MCP::OriginGuard, path: '/mcp/console')
    stack.use(Woods::MCP::BearerAuth, token: token, path: '/mcp/console')
    guarded = stack.build(endpoint)
    env = { 'PATH_INFO' => '/mcp/console', 'HTTP_ORIGIN' => 'http://localhost', 'REQUEST_METHOD' => 'POST' }
    assert(guarded.call(env).first == 401, 'Rails middleware rejects missing bearer token')
    assert(guarded.call(env.merge('HTTP_AUTHORIZATION' => 'Bearer wrong')).first == 401,
           'Rails middleware rejects bad token')
    authorized = env.merge('HTTP_AUTHORIZATION' => "Bearer #{token}")
    assert(guarded.call(authorized).first == 200, 'Rails middleware forwards authorized request')
    assert(guarded.call(authorized.merge('HTTP_ORIGIN' => 'https://evil.example')).first == 403,
           'Rails middleware refuses forbidden origin even with valid token')
  end

  def run
    installed_versions
    Dir.mktmpdir('woods-floor-index-') { |root| index_contract(root) }
    Dir.mktmpdir('woods-floor-rails-') { |root| rails_contract(root) }
    expected = "#{ENV.fetch('WOODS_MINIMUM_INSTALLED')}/lib/woods"
    loaded = $LOADED_FEATURES.grep(%r{/lib/woods(?:/|\.rb\z)})
    assert(!loaded.empty? && loaded.all? do |path|
      path.start_with?(expected)
    end, 'all Woods libraries came from installed artifact')
  end
end

MinimumDependencyProbe.run
