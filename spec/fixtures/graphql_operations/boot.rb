# frozen_string_literal: true

# Full-versus-incremental oracle for graphql_operation units, in a booted Rails
# process with the real graphql gem. Prints one JSON line naming every check
# that held; raises on the first that does not.

ENV['RAILS_ENV'] = 'test'

require 'rails'
require 'active_record/railtie'
require 'action_controller/railtie'
require 'active_job/railtie'
require 'graphql'
require 'tmpdir'
require 'fileutils'
require 'json'
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

WIDGET_TYPE = <<~RUBY
  module Types
    class WidgetType < GraphQL::Schema::Object
      graphql_name 'Widget'
      field :id, ID, null: false
      field :name, String, null: false
    end
  end
RUBY

Dir.mktmpdir('woods_graphql_operations') do |root|
  report = []
  write(root, 'config/database.yml', JSON.generate(Rails.env => { adapter: 'sqlite3', database: ':memory:' }))
  write(root, 'app/controllers/application_controller.rb',
        'class ApplicationController < ActionController::API; def index; end; end')
  write(root, 'config/routes.rb', "Rails.application.routes.draw { root 'application#index' }")
  widget_type = write(root, 'app/graphql/types/widget_type.rb', WIDGET_TYPE)
  write(root, 'app/graphql/resolvers/widgets_resolver.rb', <<~RUBY)
    module Resolvers
      class WidgetsResolver < GraphQL::Schema::Resolver
        type [Types::WidgetType], null: false
        def resolve
          raise 'extraction executed a resolver'
        end
      end
    end
  RUBY
  write(root, 'app/graphql/mutations/create_widget.rb', <<~RUBY)
    module Mutations
      class CreateWidget < GraphQL::Schema::Mutation
        argument :name, String, required: true
        field :widget, Types::WidgetType, null: true
        def resolve(name:)
          raise 'extraction executed a mutation'
        end
      end
    end
  RUBY
  write(root, 'app/graphql/types/query_type.rb', <<~RUBY)
    module Types
      class QueryType < GraphQL::Schema::Object
        field :widgets, resolver: Resolvers::WidgetsResolver
        field :widget, Types::WidgetType, null: true
      end
    end
  RUBY
  write(root, 'app/graphql/types/mutation_type.rb', <<~RUBY)
    module Types
      class MutationType < GraphQL::Schema::Object
        field :create_widget, mutation: Mutations::CreateWidget
      end
    end
  RUBY
  write(root, 'app/graphql/ledger_schema.rb', <<~RUBY)
    class LedgerSchema < GraphQL::Schema
      query Types::QueryType
      mutation Types::MutationType
    end
  RUBY
  list = write(root, 'app/javascript/widgets/widget_list.graphql', <<~GQL)
    query WidgetList {
      widgets { ...WidgetFields }
    }

    fragment WidgetFields on Widget {
      id
      name
    }
  GQL
  write(root, 'app/javascript/widgets/create_widget.gql', <<~GQL)
    mutation CreateWidget($name: String!) {
      createWidget(name: $name) { widget { ...WidgetFields } }
    }
  GQL

  app = Class.new(Rails::Application)
  Object.const_set(:GraphqlOperationsApplication, app)
  app.config.root = root
  app.config.api_only = true
  app.config.eager_load = false
  app.config.cache_classes = false
  app.config.secret_key_base = 'graphql-operations-test'
  app.config.logger = Logger.new(IO::NULL)
  app.initialize!
  ActiveRecord::Base.establish_connection(adapter: 'sqlite3', database: ':memory:')
  Rails.application.eager_load!
  Woods.configure do |config|
    config.concurrent_extraction = false
    config.enable_snapshots = false
    config.include_framework_sources = false
  end

  output = File.join(root, 'tmp/index')
  Woods::Extractor.new(output_dir: output).extract_all
  reader = Woods::MCP::IndexReader.new(output)
  operation = ->(identifier) { reader.find_unit(identifier, type: 'graphql_operation') }
  edge = ->(type, target, via) { { 'type' => type, 'target' => target, 'via' => via } }

  assert_fact(report, 'one unit per operation and per fragment') do
    reader.list_units(type: 'graphql_operation').map { |unit| unit['identifier'] }.sort ==
      %w[gql:CreateWidget gql:WidgetFields gql:WidgetList]
  end
  assert_fact(report, 'operation edges reach resolver, mutation, type and fragment units') do
    operation.call('gql:WidgetList')['dependencies'] ==
      [edge.call('graphql_resolver', 'Resolvers::WidgetsResolver', 'root_field'),
       edge.call('graphql_type', 'Types::WidgetType', 'type_reference'),
       edge.call('graphql_operation', 'gql:WidgetFields', 'fragment_spread')] &&
      operation.call('gql:CreateWidget')['dependencies'].include?(
        edge.call('graphql_mutation', 'Mutations::CreateWidget', 'root_field')
      )
  end
  assert_fact(report, 'every edge target is a published unit') do
    reader.list_units(type: 'graphql_operation').all? do |entry|
      operation.call(entry['identifier'])['dependencies'].all? do |dependency|
        reader.find_unit(dependency['target'], type: dependency['type'])
      end
    end
  end
  assert_fact(report, 'dependents of a mutation list the client document that calls it') do
    dependent = ->(identifier) { { 'type' => 'graphql_operation', 'identifier' => identifier } }
    reader.find_unit('Mutations::CreateWidget')['dependents'] == [dependent.call('gql:CreateWidget')] &&
      reader.find_unit('Types::WidgetType')['dependents'].include?(dependent.call('gql:WidgetFields'))
  end

  compare = lambda do |label|
    oracle = Dir.mktmpdir('graphql_operations_oracle')
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
  compare.call('repeat full extraction is identical')

  File.write(list, File.read(list).sub('widgets { ...WidgetFields }', "widgets { ...WidgetFields }\n  widget { id }"))
  change.call([list])
  assert_fact(report, 'document edit adds the owning-type root edge') do
    operation.call('gql:WidgetList')['dependencies']
             .include?(edge.call('graphql_query', 'Types::QueryType', 'root_field'))
  end
  compare.call('document edit full/incremental equivalence')

  added = write(root, 'app/frontend/widget_names.graphql',
                "query WidgetNames { widgets { name } }\n{ widget { id } }\n")
  change.call([added])
  assert_fact(report, 'document creation, named and anonymous') do
    operation.call('gql:WidgetNames') && operation.call('gql:app/frontend/widget_names.graphql')
  end
  compare.call('document creation full/incremental equivalence')

  duplicate = write(root, 'app/frontend/a_fragments.graphql', "fragment WidgetFields on Widget { id }\n")
  change.call([duplicate])
  assert_fact(report, 'an earlier duplicate fragment renames the later one and retargets spreads') do
    operation.call('gql:WidgetFields@app/javascript/widgets/widget_list.graphql') &&
      operation.call('gql:WidgetFields')['file_path'].end_with?('a_fragments.graphql') &&
      operation.call('gql:WidgetList')['dependencies'].include?(
        edge.call('graphql_operation', 'gql:WidgetFields@app/javascript/widgets/widget_list.graphql', 'fragment_spread')
      )
  end
  compare.call('duplicate fragment full/incremental equivalence')

  File.unlink(duplicate)
  File.unlink(added)
  change.call([duplicate, added])
  assert_fact(report, 'document deletion removes its units and restores the fragment identifier') do
    operation.call('gql:WidgetNames').nil? && operation.call('gql:app/frontend/widget_names.graphql').nil? &&
      operation.call('gql:WidgetFields')['file_path'].end_with?('widget_list.graphql') &&
      operation.call('gql:WidgetFields@app/javascript/widgets/widget_list.graphql').nil?
  end
  compare.call('document deletion full/incremental equivalence')

  File.write(widget_type, WIDGET_TYPE.sub("    field :name, String, null: false\n", ''))
  change.call([widget_type])
  assert_fact(report, 'server field removal becomes unknown_fields on an unchanged document') do
    fragment = operation.call('gql:WidgetFields')
    fragment.dig('metadata', 'unknown_fields') == ['Widget.name'] &&
      fragment.dig('metadata', 'field_selections') == ['Widget.id']
  end
  compare.call('schema drift full/incremental equivalence')

  File.write(widget_type, WIDGET_TYPE)
  Rails.application.reloader.reload!
  Woods::Extractor.new(output_dir: output).refresh(:graphql, :graphql_operations)
  assert_fact(report, 'refresh by name resolves the restored field') do
    operation.call('gql:WidgetFields').dig('metadata', 'unknown_fields') == []
  end
  compare.call('refresh full equivalence')

  puts JSON.generate(checks: report, graphql: GraphQL::VERSION, rails: Rails.version)
end
