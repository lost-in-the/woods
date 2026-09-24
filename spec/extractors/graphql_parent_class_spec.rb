# frozen_string_literal: true

require 'spec_helper'
require 'active_support/core_ext/object/blank'
require 'woods/extractors/graphql_extractor'

RSpec.describe Woods::Extractors::GraphQLExtractor, 'declared parent ownership' do
  include_context 'extractor setup'

  cases = {
    'compact qualified class' => [
      'class ParentTypes::Item < Types::BaseObject; class Wrapper < SimpleDelegator; end; end', 'Types::BaseObject'
    ],
    'lexical module wrapper' => [
      'module ParentTypes; class Item < BaseObject; class Wrapper < SimpleDelegator; end; end; end', 'BaseObject'
    ],
    'governed class wrapper' => ['class ParentTypes < NamespaceBase; class Item < BaseObject; end; end', 'BaseObject'],
    'preceding sibling' => ['module ParentTypes; class Sibling < WrongParent; end; class Item < BaseObject; end; end',
                            'BaseObject'],
    'implicit Object' => ['module ParentTypes; class Item; class Wrapper < SimpleDelegator; end; end; end', nil],
    'module interface' => [
      'module ParentTypes::Item; include GraphQL::Schema::Interface; class Wrapper < SimpleDelegator; end; end', nil
    ],
    'dynamic parent' => ['class ParentTypes::Item < ParentFactory.call; class Wrapper < SimpleDelegator; end; end',
                         nil],
    'absolute parent' => ['class ParentTypes::Item < ::Types::BaseObject; end', '::Types::BaseObject'],
    'literal declaration text' => [<<~SOURCE, nil],
      module ParentTypes
        class Item
          # class Fake < CommentParent
          TEXT = "class Fake < StringParent"
          EXAMPLE = <<~TEXT
            class Fake < HeredocParent
          TEXT
        end
      end
    SOURCE
    'invalid source' => ['class ParentTypes::Item; class Wrapper < SimpleDelegator; end', nil]
  }

  cases.each do |description, (source, parent)|
    it "uses only the selected declaration for #{description}" do
      # The marker keeps source-only fixtures eligible; padding exercises ordinary
      # chunk generation rather than calling a private summary helper.
      path = create_file('app/graphql/parent_types/item.rb',
                         "#{source.gsub('; ', "\n")}\n# < GraphQL::Schema::Object\n# #{'padding ' * 1000}\n")
      unit = described_class.new.extract_graphql_file(path)

      expect(unit).not_to be_nil
      expect(unit.identifier).to eq('ParentTypes::Item')
      expect(unit.metadata[:parent_class]).to eq(parent)
      summary = unit.chunks.find { |chunk| chunk[:chunk_type] == :summary }
      expect(summary[:content]).to include("Parent: #{parent || 'unknown'}\n")
    end
  end

  it 'uses the same declared parent for a runtime-discovered type and per-file extraction' do
    stub_const('GraphQL::Schema::Object', Class.new)
    stub_const('ParentTypes::Item', Class.new(GraphQL::Schema::Object))
    source = "class ParentTypes::Item < GraphQL::Schema::Object; class Wrapper < SimpleDelegator; end; end\n"
    path = create_file('app/graphql/parent_types/item.rb', "#{source}# #{'padding ' * 1000}\n")
    allow(Object).to receive(:const_source_location).and_call_original
    allow(Object).to receive(:const_source_location).with('ParentTypes::Item').and_return([path, 1])
    extractor = described_class.new

    [extractor.extract_from_runtime_type(ParentTypes::Item), extractor.extract_graphql_file(path)].each do |unit|
      expect(unit.metadata[:parent_class]).to eq('GraphQL::Schema::Object')
      summary = unit.chunks.find { |chunk| chunk[:chunk_type] == :summary }
      expect(summary[:content]).to include("Parent: GraphQL::Schema::Object\n")
    end
  end
end
