# frozen_string_literal: true

require 'spec_helper'
require 'woods/extractors/graphql_extractor'

RSpec.describe Woods::Extractors::GraphQLExtractor, 'runtime discovery' do
  include_context 'extractor setup'

  before do
    stub_const('GraphQL::Schema', Class.new { def self.descendants = [] })
    stub_const('GraphQL::Schema::Resolver', Class.new)
    stub_const('GraphQL::Schema::Object', Class.new)
    stub_const('GraphQL::Schema::Interface', Module.new)
    allow(Object).to receive(:const_source_location).and_call_original
  end

  def schema(name, types, query: nil)
    klass = Class.new(GraphQL::Schema)
    klass.define_singleton_method(:types) { types }
    klass.define_singleton_method(:query) { query }
    stub_const(name, klass)
    path = create_file("app/graphql/#{name.underscore}.rb", "class #{name} < GraphQL::Schema; end")
    allow(Object).to receive(:const_source_location).with(name).and_return([path, 1])
    klass
  end

  it 'publishes each schema once and preserves distinct Ruby names sharing a GraphQL name' do
    stub_const('FirstQuery', Class.new(GraphQL::Schema::Object))
    stub_const('SecondQuery', Class.new(GraphQL::Schema::Object))
    first = schema('FirstSchema', { 'Query' => FirstQuery }, query: FirstQuery)
    second = schema('SecondSchema', { 'Query' => SecondQuery, 'Shared' => FirstQuery }, query: SecondQuery)
    allow(GraphQL::Schema).to receive(:descendants).and_return([first, second])

    extractor = described_class.new
    expect(extractor.discoverable_classes.map(&:name)).to match_array(%w[FirstSchema SecondSchema FirstQuery
                                                                         SecondQuery])
    units = extractor.extract_all
    expect(units.map(&:identifier)).to match_array(%w[FirstSchema SecondSchema FirstQuery SecondQuery])
    expect(units.select { |u| u.type == :graphql_query }.map(&:identifier)).to match_array(%w[FirstQuery SecondQuery])
    expect(units.find { |u| u.identifier == 'FirstSchema' }.metadata[:graphql_kind]).to eq(:schema)
  end

  it 'warns for one failing schema while retaining other schema inventories' do
    stub_const('HealthyQuery', Class.new(GraphQL::Schema::Object))
    broken = schema('BrokenSchema', {})
    healthy = schema('HealthySchema', { 'Query' => HealthyQuery }, query: HealthyQuery)
    allow(broken).to receive(:types).and_raise(StandardError, 'type inventory unavailable')
    allow(GraphQL::Schema).to receive(:descendants).and_return([broken, healthy])
    expect(Rails.logger).to receive(:warn).with(/BrokenSchema.*type inventory unavailable/)

    extractor = described_class.new
    expect(extractor.discoverable_classes.map(&:name)).to include('HealthyQuery', 'HealthySchema', 'BrokenSchema')
    expect(extractor.runtime_discovery_complete?).to be(false)
  end

  it 'does not treat failed schema discovery as an empty app when app/graphql is absent' do
    allow(GraphQL::Schema).to receive(:descendants).and_raise(StandardError, 'inventory unavailable')
    expect(Rails.logger).to receive(:warn).with(/schema inventory.*inventory unavailable/)

    expect { described_class.new.extract_all }
      .to raise_error(Woods::ExtractionError, /GraphQL runtime discovery incomplete/)
  end

  it 'classifies loaded resolver chains independently of superclass spelling' do
    stub_const('Resolvers::Authorized', Class.new(GraphQL::Schema::Resolver))
    { 'Child' => 'Resolvers::Authorized', 'Root' => '::GraphQL::Schema::Resolver',
      'Spaced' => ' GraphQL::Schema::Resolver' }.each do |name, parent|
      stub_const("Resolvers::#{name}", Class.new(Resolvers::Authorized))
      path = create_file("app/graphql/resolvers/#{name.underscore}.rb", "class Resolvers::#{name} < #{parent}; end")
      expect(described_class.new.extract_graphql_file(path)&.type).to eq(:graphql_resolver)
    end
  end

  it 'does not misclassify object types as interfaces merely because they expose fields' do
    stub_const('AppQuery', Class.new(GraphQL::Schema::Object) { def self.fields = {} })
    app = schema('AppSchema', { 'Query' => AppQuery }, query: AppQuery)
    allow(GraphQL::Schema).to receive(:descendants).and_return([app])

    expect(described_class.new.extract_from_runtime_type(AppQuery).type).to eq(:graphql_query)
  end

  it 'does not accept a loaded unrelated class because its source contains a GraphQL example' do
    stub_const('PlainGraphqlExample', Class.new)
    path = create_file('app/graphql/plain_graphql_example.rb', <<~RUBY)
      class PlainGraphqlExample
        EXAMPLE = 'class Example < GraphQL::Schema::Object'
      end
    RUBY
    expect(described_class.new.extract_graphql_file(path)).to be_nil
  end

  it 'does not trigger an unresolved declaration autoload' do
    stub_const('DormantGraphql', Module.new)
    autoload_path = create_file('lib/dormant.rb', "raise 'must not autoload'")
    DormantGraphql.autoload(:Resolver, autoload_path)
    path = create_file('app/graphql/dormant_graphql/resolver.rb',
                       'class DormantGraphql::Resolver < GraphQL::Schema::Resolver; end')

    expect(described_class.new.extract_graphql_file(path)&.identifier).to eq('DormantGraphql::Resolver')
    expect(DormantGraphql.autoload?(:Resolver)).to eq(autoload_path)
  end

  it 'ignores stale reload descendants and schemas owned outside the application' do
    stale = schema('ReloadedSchema', {})
    current = schema('ReloadedSchema', {})
    foreign = schema('ForeignSchema', {})
    allow(Object).to receive(:const_source_location).with('ForeignSchema').and_return([__FILE__, 1])
    allow(GraphQL::Schema).to receive(:descendants).and_return([stale, current, foreign])

    expect(described_class.new.discoverable_classes).to eq([current])
  end

  it 'uses the real declaration source ahead of an unrelated convention-named file' do
    stub_const('LocatedType', Class.new(GraphQL::Schema::Object))
    actual = create_file('config/initializers/types.rb', 'LocatedType = Class.new(GraphQL::Schema::Object)')
    create_file('app/graphql/located_type.rb', '# not the declaration')
    allow(Object).to receive(:const_source_location).with('LocatedType').and_return([actual, 1])

    unit = described_class.new.extract_from_runtime_type(LocatedType)
    expect(unit.file_path).to eq(actual)
    expect(unit.source_code).to include('LocatedType = Class.new')
  end

  %i[Object InputObject Enum Union Scalar Mutation Resolver].each do |family|
    it "accepts verified #{family} ancestry through an application superclass" do
      stub_const("GraphQL::Schema::#{family}", Class.new)
      parent = Class.new(GraphQL::Schema.const_get(family))
      stub_const('CustomGraphqlParent', parent)
      stub_const('CustomGraphqlChild', Class.new(parent))
      path = create_file('app/graphql/custom_graphql_child.rb', 'class CustomGraphqlChild < CustomGraphqlParent; end')

      expect(described_class.new.extract_graphql_file(path)&.identifier).to eq('CustomGraphqlChild')
    end
  end
end
