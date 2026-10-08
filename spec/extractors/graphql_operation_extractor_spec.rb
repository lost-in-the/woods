# frozen_string_literal: true

require 'spec_helper'
require 'json'
require 'open3'
require 'rbconfig'
require 'tmpdir'
require 'fileutils'
require 'woods'
require 'woods/extractors/graphql_operation_extractor'

RSpec.describe Woods::Extractors::GraphQLOperationExtractor do
  def run_fixture(mode)
    script = File.expand_path('../fixtures/graphql_operations/extract.rb', __dir__)
    output, error, status = Open3.capture3({ 'MODE' => mode }, RbConfig.ruby, '-Ilib', script)
    raise "fixture failed (#{mode}): #{error}\n#{output}" unless status.success?

    JSON.parse(output.lines.last.force_encoding('UTF-8'))
  end

  def unit(result, identifier)
    result.fetch('units').find { |candidate| candidate['identifier'] == identifier } ||
      raise("no unit #{identifier} in #{result.fetch('units').map { |u| u['identifier'] }.inspect}")
  end

  def edges(unit, via)
    unit.fetch('dependencies').select { |edge| edge['via'] == via }
        .map { |edge| edge.values_at('type', 'target') }
  end

  context 'with graphql-ruby and a booted schema' do
    before(:all) { @result = run_fixture('default') }

    let(:result) { @result }
    let(:widget_list) { unit(result, 'gql:WidgetList') }
    let(:duplicate_id) { 'gql:WidgetFields@app/javascript/zz/duplicate.graphql' }

    it 'emits one graphql_operation unit per operation and per fragment' do
      expect(result.fetch('units').map { |u| u['identifier'] }).to eq(
        ['gql:Search', 'gql:app/javascript/widgets/anonymous.graphql', 'gql:CreateWidget', 'gql:WidgetChanged',
         'gql:WidgetList', 'gql:WidgetFields', duplicate_id]
      )
      expect(result.fetch('units').map { |u| u['type'] }.uniq).to eq(['graphql_operation'])
    end

    it 'records kind, name, document path and line' do
      expect(widget_list.fetch('metadata')).to include(
        'kind' => 'query', 'operation_name' => 'WidgetList',
        'document_path' => 'app/javascript/widgets/widget_list.graphql', 'line' => 2, 'schema' => 'LedgerSchema'
      )
      expect(widget_list.fetch('file_path'))
        .to eq(File.join(result.fetch('root'), 'app/javascript/widgets/widget_list.graphql'))
      expect(unit(result, 'gql:WidgetFields').fetch('metadata'))
        .to include('kind' => 'fragment', 'type_condition' => 'Widget', 'line' => 11)
      expect(unit(result, 'gql:CreateWidget').dig('metadata', 'kind')).to eq('mutation')
      expect(unit(result, 'gql:WidgetChanged').dig('metadata', 'kind')).to eq('subscription')
    end

    it 'records variables in declaration order with type and default' do
      expect(widget_list.dig('metadata', 'variables')).to eq(
        [{ 'name' => 'first', 'type' => 'Int', 'default' => '10' },
         { 'name' => 'ids', 'type' => '[ID!]', 'default' => nil }]
      )
    end

    it 'records top-level fields without introspection fields' do
      expect(widget_list.dig('metadata', 'top_level_fields')).to eq(['widgets'])
    end

    it 'records every resolved selection as Type.field, sorted' do
      expect(widget_list.dig('metadata', 'field_selections'))
        .to eq(%w[Owner.id Query.widgets Widget.id Widget.owner])
      expect(unit(result, 'gql:WidgetFields').dig('metadata', 'field_selections'))
        .to eq(%w[Part.sku Widget.id Widget.name Widget.parts])
    end

    it 'slices each definition out of its document' do
      expect(widget_list.fetch('source_code')).to start_with('query WidgetList($first: Int = 10')
      expect(widget_list.fetch('source_code')).not_to include('fragment WidgetFields')
      expect(unit(result, 'gql:WidgetFields').fetch('source_code')).to start_with('fragment WidgetFields on Widget {')
    end

    it 'links a resolver-backed root field to the resolver unit' do
      expect(edges(widget_list, 'root_field')).to eq([['graphql_resolver', 'Resolvers::WidgetsResolver']])
    end

    it 'links a mutation root field to the mutation unit' do
      expect(edges(unit(result, 'gql:CreateWidget'), 'root_field'))
        .to eq([['graphql_mutation', 'Mutations::CreateWidget']])
    end

    it 'links a plain root field to the type that defines it' do
      expect(edges(unit(result, 'gql:app/javascript/widgets/anonymous.graphql'), 'root_field'))
        .to eq([['graphql_query', 'Types::QueryType']])
    end

    it 'links the types an operation selects, by Ruby class name' do
      expect(edges(widget_list, 'type_reference'))
        .to eq([['graphql_type', 'Types::OwnerType'], ['graphql_type', 'Types::WidgetType']])
      expect(edges(unit(result, 'gql:Search'), 'type_reference'))
        .to eq([['graphql_type', 'Types::SearchResultType'], ['graphql_type', 'Types::WidgetType']])
    end

    it 'emits no edge for an anonymous payload type' do
      targets = unit(result, 'gql:CreateWidget').fetch('dependencies').map { |edge| edge['target'] }
      expect(targets).to contain_exactly('Mutations::CreateWidget', 'Types::WidgetType', 'gql:WidgetFields',
                                         duplicate_id)
    end

    it 'links a spread to the fragment in the same document' do
      expect(widget_list.dig('metadata', 'fragment_spreads')).to eq(['WidgetFields'])
      expect(edges(widget_list, 'fragment_spread')).to eq([['graphql_operation', 'gql:WidgetFields']])
    end

    it 'links a cross-document spread to every fragment of that name' do
      expect(edges(unit(result, 'gql:CreateWidget'), 'fragment_spread'))
        .to eq([['graphql_operation', 'gql:WidgetFields'], ['graphql_operation', duplicate_id]])
    end

    it 'records schema drift in metadata and never as an edge' do
      expect(widget_list.dig('metadata', 'unknown_fields')).to eq(['Owner.legacyCode'])
      search = unit(result, 'gql:Search')
      expect(search.dig('metadata', 'unknown_types')).to eq(['Gadget'])
      expect(search.dig('metadata', 'unknown_fragments')).to eq(['MissingFields'])
      expect(unit(result, 'gql:WidgetChanged').dig('metadata', 'unknown_fields'))
        .to eq(['Subscription.widgetChanged'])
      all_targets = result.fetch('units').flat_map { |u| u.fetch('dependencies').map { |edge| edge['target'] } }
      expect(all_targets.grep(/legacy|Gadget|Missing|widgetChanged/)).to eq([])
    end

    it 'skips schema definition documents and unparseable documents, and says so' do
      expect(result.fetch('log')).to include('app/javascript/schema.graphql')
      expect(result.fetch('log')).to include('app/javascript/broken.graphql')
    end

    it 'ignores documents outside the configured roots and under node_modules' do
      paths = result.fetch('units').map { |u| u.dig('metadata', 'document_path') }
      expect(paths.grep(%r{node_modules|app/assets})).to eq([])
    end

    it 'produces identical output on a repeat run' do
      expect(result.fetch('repeat_identical')).to be(true)
    end
  end

  context 'with graphql-ruby but no application schema' do
    before(:all) { @result = run_fixture('no_schema') }

    it 'still emits units, with no schema edges and no drift claims' do
      list = unit(@result, 'gql:WidgetList')
      expect(list.fetch('metadata')).to include('schema' => nil, 'unknown_fields' => [], 'field_selections' => [])
      expect(edges(list, 'fragment_spread')).to eq([['graphql_operation', 'gql:WidgetFields']])
      expect(edges(list, 'root_field') + edges(list, 'type_reference')).to eq([])
    end
  end

  context 'without graphql-ruby' do
    include_context 'extractor setup'

    it 'skips the family with a logged note' do
      hide_const('GraphQL') if defined?(GraphQL)
      create_file('app/javascript/widgets/widget_list.graphql', 'query WidgetList { widgets { id } }')

      expect(described_class.new.extract_all).to eq([])
      expect(logger).to have_received(:info).with(/graphql gem is not loaded/)
    end

    it 'stays silent when there are no documents' do
      hide_const('GraphQL') if defined?(GraphQL)

      expect(described_class.new.extract_all).to eq([])
      expect(logger).not_to have_received(:info)
    end
  end
end
