# frozen_string_literal: true

# Runs GraphQLOperationExtractor against a synthetic tree with the real graphql
# gem loaded. A subprocess, because the unit suite stubs the GraphQL constants
# and must never see the real gem. Prints one JSON line.
#
# MODE=default      schema plus documents
# MODE=no_schema    documents only
# MODE=adversarial  oversized documents, timed

require 'graphql'
require 'active_support'
require 'active_support/core_ext'
require 'tmpdir'
require 'fileutils'
require 'json'
require 'logger'
require 'pathname'
require 'stringio'
require 'woods'
require 'woods/extracted_unit'
require 'woods/extractors/graphql_operation_extractor'

Regexp.timeout = 1 if Regexp.respond_to?(:timeout=)

def write(root, relative, source)
  path = File.join(root, relative)
  FileUtils.mkdir_p(File.dirname(path))
  File.write(path, source)
  path
end

SCHEMA_FILES = {
  'app/graphql/types/part_type.rb' => <<~RUBY,
    module Types
      class PartType < GraphQL::Schema::Object
        field :sku, String, null: false
      end
    end
  RUBY
  'app/graphql/types/owner_type.rb' => <<~RUBY,
    module Types
      class OwnerType < GraphQL::Schema::Object
        field :id, ID, null: false
      end
    end
  RUBY
  'app/graphql/types/widget_type.rb' => <<~RUBY,
    module Types
      class WidgetType < GraphQL::Schema::Object
        graphql_name 'Widget'
        field :id, ID, null: false
        field :name, String, null: false
        field :owner, Types::OwnerType, null: true
        field :parts, [Types::PartType], null: false
      end
    end
  RUBY
  'app/graphql/types/search_result_type.rb' => <<~RUBY,
    module Types
      class SearchResultType < GraphQL::Schema::Union
        possible_types Types::WidgetType, Types::OwnerType
        def self.resolve_type(_object, _context) = raise('extraction executed resolve_type')
      end
    end
  RUBY
  'app/graphql/resolvers/widgets_resolver.rb' => <<~RUBY,
    module Resolvers
      class WidgetsResolver < GraphQL::Schema::Resolver
        type [Types::WidgetType], null: false
        argument :first, Integer, required: false
        def resolve(first: nil) = raise('extraction executed a resolver')
      end
    end
  RUBY
  'app/graphql/mutations/create_widget.rb' => <<~RUBY,
    module Mutations
      class CreateWidget < GraphQL::Schema::Mutation
        argument :name, String, required: true
        field :widget, Types::WidgetType, null: true
        def resolve(name:) = raise('extraction executed a mutation')
      end
    end
  RUBY
  'app/graphql/types/query_type.rb' => <<~RUBY,
    module Types
      class QueryType < GraphQL::Schema::Object
        field :widgets, resolver: Resolvers::WidgetsResolver
        field :widget, Types::WidgetType, null: true do
          argument :id, ID, required: true
        end
        field :search, [Types::SearchResultType], null: false
      end
    end
  RUBY
  'app/graphql/types/mutation_type.rb' => <<~RUBY,
    module Types
      class MutationType < GraphQL::Schema::Object
        field :create_widget, mutation: Mutations::CreateWidget
      end
    end
  RUBY
  'app/graphql/ledger_schema.rb' => <<~RUBY
    class LedgerSchema < GraphQL::Schema
      query Types::QueryType
      mutation Types::MutationType
    end
  RUBY
}.freeze

DOCUMENTS = {
  'app/javascript/widgets/widget_list.graphql' => <<~GQL,
    # Lists widgets
    query WidgetList($first: Int = 10, $ids: [ID!]) {
      widgets(first: $first) {
        id
        ...WidgetFields
        owner { id legacyCode }
      }
      __typename
    }

    fragment WidgetFields on Widget {
      id
      name
      parts { sku }
    }
  GQL
  'app/javascript/widgets/create_widget.gql' => <<~GQL,
    mutation CreateWidget($name: String!) {
      createWidget(name: $name) { widget { ...WidgetFields } }
    }
  GQL
  'app/javascript/widgets/anonymous.graphql' => "{ widget(id: 1) { id } }\n",
  'app/javascript/widgets/watch.graphql' => "subscription WidgetChanged { widgetChanged { id } }\n",
  'app/javascript/zz/duplicate.graphql' => "fragment WidgetFields on Widget { id }\n",
  'app/frontend/search.graphql' => <<~GQL,
    query Search {
      search {
        __typename
        ... on Widget { name }
        ... on Gadget { id }
        ...MissingFields
      }
    }
  GQL
  'app/javascript/schema.graphql' => "type Widget { id: ID! }\n",
  'app/javascript/broken.graphql' => "query {\n",
  'app/javascript/node_modules/pkg/vendored.graphql' => "query Vendored { widgets { id } }\n",
  'app/assets/outside.graphql' => "query Outside { widgets { id } }\n"
}.freeze

ADVERSARIAL = {
  'app/javascript/adv/flat.graphql' => "query Flat { #{'widgets { id } ' * 50_000}}\n",
  'app/javascript/adv/spreads.graphql' => "query Spreads { widgets { #{'...WidgetFieldz ' * 10_000}} }\n",
  'app/javascript/adv/unknown.graphql' => "query Unknown { #{(0...10_000).map { |i| "widgetz#{i} " }.join}}\n",
  'app/javascript/adv/nested.graphql' => "query Nested #{'{ widgets ' * 50_000}#{'}' * 50_000}\n",
  'app/javascript/adv/many.graphql' => (0...10_000).map { |i| "fragment F#{i} on Widget { id }\n" }.join,
  'app/javascript/adv/comments.graphql' => "#{"# query Widget {\n" * 50_000}query Commented { widgets { id } }\n",
  'app/javascript/adv/trailing.graphql' =>
    "query Trailing { widgets { id } }\n#{"# fragment Widget\n\n" * 50_000}fragment Tail on Widget { id }\n"
}.freeze

mode = ENV.fetch('MODE', 'default')

Dir.mktmpdir('woods_gql_operations') do |tmp|
  root = File.realpath(tmp)
  log = StringIO.new
  rails = Module.new
  rails.define_singleton_method(:root) { Pathname.new(root) }
  logger = Logger.new(log)
  rails.define_singleton_method(:logger) { logger }
  Object.const_set(:Rails, rails)

  unless mode == 'no_schema'
    SCHEMA_FILES.each { |relative, source| write(root, relative, source) }
    SCHEMA_FILES.each_key { |relative| require File.join(root, relative) }
  end
  DOCUMENTS.each { |relative, source| write(root, relative, source) }
  ADVERSARIAL.each { |relative, source| write(root, relative, source) } if mode == 'adversarial'

  serialize = lambda do
    Woods::Extractors::GraphQLOperationExtractor.new.extract_all.map do |unit|
      JSON.parse(JSON.generate(unit.to_h.except(:extracted_at)))
    end
  end

  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  units = serialize.call
  elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
  repeat = serialize.call

  payload = { repeat_identical: JSON.generate(units) == JSON.generate(repeat), elapsed: elapsed,
              root: root, log: log.string, graphql: GraphQL::VERSION }
  payload[:units] = units
  if mode == 'adversarial'
    payload[:units] = units.map do |unit|
      { 'identifier' => unit['identifier'],
        'counts' => unit['metadata'].slice('unknown_fields', 'unknown_fragments', 'field_selections')
                                    .transform_values(&:size) }
    end
  end
  puts JSON.generate(payload)
end
