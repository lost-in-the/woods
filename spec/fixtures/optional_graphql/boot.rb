# frozen_string_literal: true

ENV['RAILS_ENV'] = 'test'

require 'rails'
require 'active_record/railtie'
require 'action_controller/railtie'
require 'active_job/railtie'
require 'graphql'
require 'tmpdir'
require 'fileutils'
require 'json'
require 'open3'
require 'woods'
require 'woods/extractor'
require 'woods/mcp/index_reader'
require_relative '../../support/index_comparison'

def write(root, relative, source)
  path = File.join(root, relative)
  FileUtils.mkdir_p(File.dirname(path))
  File.write(path, source)
  path
end

def assert_fact(report, name)
  raise name unless yield

  report << name
end

Dir.mktmpdir('woods_graphql_discovery') do |root|
  report = []
  write(root, 'config/database.yml', JSON.generate(Rails.env => { adapter: 'sqlite3', database: ':memory:' }))
  write(root, 'app/controllers/application_controller.rb',
        'class ApplicationController < ActionController::API; def index; end; end')
  write(root, 'config/routes.rb', "Rails.application.routes.draw { root 'application#index' }")
  write(root, 'app/graphql/discovery_promoted_type.rb', <<~RUBY)
    class DiscoveryPromotedType < GraphQL::Schema::Object
      field :value, String, null: false
      def value
        raise 'extraction executed a field' if ENV['GRAPHQL_DISCOVERY_NO_EXECUTION']
        'value'
      end
    end
  RUBY
  write(root, 'app/models/discovery_caller.rb', 'class DiscoveryCaller; def call; DiscoveryPromotedType; end; end')
  write(root, 'app/graphql/discovery_authorized_resolver.rb', <<~RUBY)
    class DiscoveryAuthorizedResolver < GraphQL::Schema::Resolver
      type String, null: false
      def resolve
        raise 'extraction executed a resolver' if ENV['GRAPHQL_DISCOVERY_NO_EXECUTION']
        'ok'
      end
    end
  RUBY
  child = write(root, 'app/graphql/discovery_child_resolver.rb',
                'class DiscoveryChildResolver < DiscoveryAuthorizedResolver; end')
  write(root, 'app/graphql/discovery_root_resolver.rb',
        'class DiscoveryRootResolver < ::GraphQL::Schema::Resolver; type String, null: false; end')
  write(root, 'app/graphql/discovery_spaced_resolver.rb',
        'class DiscoverySpacedResolver <  GraphQL::Schema::Resolver; type String, null: false; end')
  write(root, 'app/graphql/discovery_query.rb', <<~RUBY)
    class DiscoveryQuery < GraphQL::Schema::Object
      field :hello, String, null: false
      field :child, resolver: DiscoveryChildResolver
      field :promotable, DiscoveryPromotedType, null: true
      def hello
        raise 'extraction executed a field' if ENV['GRAPHQL_DISCOVERY_NO_EXECUTION']
        'hello'
      end
    end
  RUBY
  schema = write(root, 'app/graphql/discovery_schema.rb', <<~RUBY)
    class DiscoverySchema < GraphQL::Schema
      query DiscoveryQuery
      max_complexity 123
    end
  RUBY
  write(root, 'config/initializers/runtime_graphql.rb', <<~RUBY)
    DiscoveryRuntimeQueryA = Class.new(GraphQL::Schema::Object) do
      graphql_name 'RuntimeQuery'
      field :hello, String, null: false
      def hello
        raise 'extraction executed a field' if ENV['GRAPHQL_DISCOVERY_NO_EXECUTION']
        'A'
      end
    end
    DiscoveryRuntimeSchemaA = Class.new(GraphQL::Schema) do
      query DiscoveryRuntimeQueryA
    end
    DiscoveryRuntimeQueryB = Class.new(GraphQL::Schema::Object) do
      graphql_name 'RuntimeQuery'
      field :hello, String, null: false
      def hello
        raise 'extraction executed a field' if ENV['GRAPHQL_DISCOVERY_NO_EXECUTION']
        'B'
      end
    end
    DiscoveryRuntimeSchemaB = Class.new(GraphQL::Schema) do
      query DiscoveryRuntimeQueryB
    end
  RUBY

  app = Class.new(Rails::Application)
  Object.const_set(:GraphqlDiscoveryApplication, app)
  app.config.root = root
  app.config.api_only = true
  app.config.eager_load = false
  app.config.cache_classes = false
  app.config.secret_key_base = 'graphql-discovery-test'
  app.config.logger = Logger.new(IO::NULL)
  app.initialize!
  ActiveRecord::Base.establish_connection(adapter: 'sqlite3', database: ':memory:')
  Rails.application.eager_load!
  assert_fact(report, 'three working schemas') do
    DiscoverySchema.execute('{ hello child }').to_h == { 'data' => { 'hello' => 'hello', 'child' => 'ok' } } &&
      DiscoveryRuntimeSchemaA.execute('{ hello }').to_h == { 'data' => { 'hello' => 'A' } } &&
      DiscoveryRuntimeSchemaB.execute('{ hello }').to_h == { 'data' => { 'hello' => 'B' } }
  end
  ENV['GRAPHQL_DISCOVERY_NO_EXECUTION'] = '1'
  Woods.configure do |config|
    config.concurrent_extraction = false
    config.enable_snapshots = false
    config.include_framework_sources = false
  end
  output = File.join(root, 'tmp/index')
  Woods::Extractor.new(output_dir: output).extract_all
  reader = Woods::MCP::IndexReader.new(output)
  assert_fact(report, 'schema source and metadata') do
    unit = reader.find_unit('DiscoverySchema')
    unit && unit['type'] == 'graphql_type' && unit.dig('metadata', 'graphql_kind') == 'schema' &&
      unit['source_code'].include?('max_complexity 123')
  end
  assert_fact(report, 'every schema inventory and shared query-root identity') do
    %w[DiscoveryQuery DiscoveryRuntimeQueryA DiscoveryRuntimeQueryB].all? do |name|
      reader.find_unit(name)&.fetch('type') == 'graphql_query'
    end
  end
  assert_fact(report, 'all resolver spellings and inherited resolver') do
    %w[DiscoveryAuthorizedResolver DiscoveryChildResolver DiscoveryRootResolver DiscoverySpacedResolver].all? do |name|
      reader.find_unit(name)&.fetch('type') == 'graphql_resolver'
    end
  end

  # Exercise the shipped executable registration/serialization, not a custom tool.
  preload = write(root, 'mcp_json.rb', "require 'woods'; Woods.configuration.context_format = :json")
  requests = [
    { jsonrpc: '2.0', id: 1, method: 'initialize', params: { protocolVersion: '2024-11-05', capabilities: {},
                                                             clientInfo: { name: 'graphql-check', version: '1' } } },
    { jsonrpc: '2.0', method: 'notifications/initialized' },
    { jsonrpc: '2.0', id: 2, method: 'tools/call',
      params: { name: 'lookup', arguments: { identifier: 'DiscoverySchema', type: 'graphql_type' } } },
    { jsonrpc: '2.0', id: 3, method: 'tools/call',
      params: { name: 'search', arguments: { query: 'max_complexity', fields: ['source_code'] } } }
  ]
  stdout, stderr, status = Open3.capture3(RbConfig.ruby, '-Ilib', '-r', preload, 'exe/woods-mcp', output,
                                          stdin_data: "#{requests.map { |r| JSON.generate(r) }.join("\n")}\n")
  raise stderr unless status.success?

  responses = stdout.lines.map { |line| JSON.parse(line) }.to_h { |response| [response['id'], response] }
  assert_fact(report, 'packaged MCP typed lookup and source search') do
    responses.dig(2, 'result', 'structuredContent', 'data', 'identifier') == 'DiscoverySchema' &&
      responses.fetch(3).to_json.include?('DiscoverySchema') && !responses.dig(3, 'result', 'isError')
  end

  compare = lambda do |label|
    oracle = Dir.mktmpdir('graphql_oracle')
    Woods::Extractor.new(output_dir: oracle).extract_all
    differences = IndexComparison.differences(output, oracle)
    raise "#{label}: #{differences.inspect}" unless differences.empty?

    report << label
  ensure
    FileUtils.rm_rf(oracle) if oracle
  end
  change = lambda do |paths|
    Rails.application.reloader.reload!
    Woods::Extractor.new(output_dir: output).extract_changed(paths)
  end
  File.write(schema, File.read(schema).sub('123', '321'))
  change.call([schema])
  assert_fact(report, 'incremental schema edit') do
    reader.find_unit('DiscoverySchema')['source_code'].include?('max_complexity 321')
  end
  compare.call('schema edit full/incremental equivalence')
  File.write(child, 'class DiscoveryChildResolver <  ::DiscoveryAuthorizedResolver; end')
  change.call([child])
  assert_fact(report, 'format-only resolver edit preserves identity') do
    reader.find_unit('DiscoveryChildResolver')['type'] == 'graphql_resolver'
  end
  compare.call('resolver edit full/incremental equivalence')
  added = write(root, 'app/graphql/discovery_added_resolver.rb',
                'class DiscoveryAddedResolver < DiscoveryAuthorizedResolver; end')
  change.call([added])
  assert_fact(report, 'incremental resolver creation') do
    reader.find_unit('DiscoveryAddedResolver')['type'] == 'graphql_resolver'
  end
  File.unlink(added)
  change.call([added])
  assert_fact(report, 'incremental resolver deletion') { reader.find_unit('DiscoveryAddedResolver').nil? }
  compare.call('resolver deletion full/incremental equivalence')

  promotion = write(root, 'app/graphql/discovery_added_schema.rb',
                    'class DiscoveryAddedSchema < GraphQL::Schema; query DiscoveryPromotedType; end')
  change.call([promotion])
  assert_fact(report, 'new schema promotes unchanged object to query root') do
    reader.find_unit('DiscoveryPromotedType')['type'] == 'graphql_query'
  end
  assert_fact(report, 'unchanged caller follows promoted typed target') do
    reader.find_unit('DiscoveryCaller')['dependencies'].include?('type' => 'graphql_query',
                                                                 'target' => 'DiscoveryPromotedType',
                                                                 'via' => 'code_reference')
  end
  compare.call('root promotion full/incremental equivalence')
  DiscoveryAddedSchema.define_singleton_method(:query) { raise 'schema introspection temporarily unavailable' }
  marker = File.binread(File.join(output, 'generation.json'))
  %i[incremental refresh full].each do |operation|
    extractor = Woods::Extractor.new(output_dir: output)
    case operation
    when :incremental then extractor.extract_changed([])
    when :refresh then extractor.refresh(:graphql)
    when :full then extractor.extract_all
    end
    raise "#{operation} published an incomplete schema inventory"
  rescue Woods::ExtractionError
    assert_fact(report, "failed schema inventory preserves prior generation during #{operation}") do
      File.binread(File.join(output, 'generation.json')) == marker &&
        reader.find_unit('DiscoveryPromotedType')['type'] == 'graphql_query'
    end
  end
  DiscoveryAddedSchema.singleton_class.remove_method(:query)
  File.unlink(promotion)
  change.call([promotion])
  assert_fact(report, 'removed schema demotes retained object') do
    reader.find_unit('DiscoveryPromotedType')['type'] == 'graphql_type'
  end
  compare.call('root demotion full/incremental equivalence')
  write(root, 'app/graphql/discovery_added_schema.rb',
        'class DiscoveryAddedSchema < GraphQL::Schema; query DiscoveryPromotedType; end')
  Rails.application.reloader.reload!
  Woods::Extractor.new(output_dir: output).refresh(:graphql)
  assert_fact(report, 'refresh promotion preserves replacement payload and removes old typed identity') do
    reader.find_unit('DiscoveryPromotedType', type: 'graphql_type').nil? &&
      reader.find_unit('DiscoveryPromotedType', type: 'graphql_query')
  end
  compare.call('refresh promotion full equivalence')
  File.unlink(promotion)
  promoted = File.join(root, 'app/graphql/discovery_promoted_type.rb')
  File.write(promoted, "#{File.read(promoted)}\n# changed alongside schema removal\n")
  change.call([promotion, promoted])
  assert_fact(report, 'changed-file demotion preserves replacement payload and removes old typed identity') do
    reader.find_unit('DiscoveryPromotedType', type: 'graphql_query').nil? &&
      reader.find_unit('DiscoveryPromotedType', type: 'graphql_type')
  end
  compare.call('changed-file demotion full equivalence')
  Woods::Extractor.new(output_dir: output).refresh(:graphql)
  compare.call('GraphQL refresh full equivalence')
  puts JSON.generate(checks: report, graphql: GraphQL::VERSION, rails: Rails.version)
end
