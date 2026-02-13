# frozen_string_literal: true

require 'spec_helper'
require 'codebase_index/ast'
require 'codebase_index/ruby_analyzer/dataflow_analyzer'

RSpec.describe CodebaseIndex::RubyAnalyzer::DataFlowAnalyzer do
  subject(:analyzer) { described_class.new }

  def make_unit(identifier:, source_code:, type: :ruby_method)
    unit = CodebaseIndex::ExtractedUnit.new(
      type: type,
      identifier: identifier,
      file_path: '/app/test.rb'
    )
    unit.source_code = source_code
    unit.metadata = {}
    unit
  end

  describe '#annotate' do
    it 'detects .new calls as construction' do
      unit = make_unit(
        identifier: 'Foo#create',
        source_code: 'def create; User.new(params); end'
      )

      analyzer.annotate([unit])

      expect(unit.metadata[:data_transformations]).to include(
        a_hash_including(method: 'new', category: :construction)
      )
    end

    it 'detects .to_h as serialization' do
      unit = make_unit(
        identifier: 'Foo#serialize',
        source_code: 'def serialize; result.to_h; end'
      )

      analyzer.annotate([unit])

      expect(unit.metadata[:data_transformations]).to include(
        a_hash_including(method: 'to_h', category: :serialization)
      )
    end

    it 'detects .to_json as serialization' do
      unit = make_unit(
        identifier: 'Foo#export',
        source_code: 'def export; data.to_json; end'
      )

      analyzer.annotate([unit])

      expect(unit.metadata[:data_transformations]).to include(
        a_hash_including(method: 'to_json', category: :serialization)
      )
    end

    it 'detects .to_a as serialization' do
      unit = make_unit(
        identifier: 'Foo#list',
        source_code: 'def list; items.to_a; end'
      )

      analyzer.annotate([unit])

      expect(unit.metadata[:data_transformations]).to include(
        a_hash_including(method: 'to_a', category: :serialization)
      )
    end

    it 'detects .as_json as serialization' do
      unit = make_unit(
        identifier: 'Foo#render',
        source_code: 'def render; model.as_json; end'
      )

      analyzer.annotate([unit])

      expect(unit.metadata[:data_transformations]).to include(
        a_hash_including(method: 'as_json', category: :serialization)
      )
    end

    it 'detects .serialize as serialization' do
      unit = make_unit(
        identifier: 'Foo#save',
        source_code: 'def save; record.serialize; end'
      )

      analyzer.annotate([unit])

      expect(unit.metadata[:data_transformations]).to include(
        a_hash_including(method: 'serialize', category: :serialization)
      )
    end

    it 'detects .from_json as deserialization' do
      unit = make_unit(
        identifier: 'Foo#load',
        source_code: 'def load; Config.from_json(data); end'
      )

      analyzer.annotate([unit])

      expect(unit.metadata[:data_transformations]).to include(
        a_hash_including(method: 'from_json', category: :deserialization)
      )
    end

    it 'detects .parse as deserialization' do
      unit = make_unit(
        identifier: 'Foo#read',
        source_code: 'def read; JSON.parse(input); end'
      )

      analyzer.annotate([unit])

      expect(unit.metadata[:data_transformations]).to include(
        a_hash_including(method: 'parse', category: :deserialization)
      )
    end

    it 'detects multiple transformations in one method' do
      unit = make_unit(
        identifier: 'Foo#convert',
        source_code: <<~RUBY
          def convert(json_str)
            data = JSON.parse(json_str)
            result = Converter.new(data)
            result.to_h
          end
        RUBY
      )

      analyzer.annotate([unit])

      transformations = unit.metadata[:data_transformations]
      expect(transformations.size).to be >= 3
      categories = transformations.map { |t| t[:category] }
      expect(categories).to include(:deserialization, :construction, :serialization)
    end

    it 'annotates class units as well' do
      unit = make_unit(
        identifier: 'Foo',
        type: :ruby_class,
        source_code: <<~RUBY
          class Foo
            def build
              User.new(params).to_json
            end
          end
        RUBY
      )

      analyzer.annotate([unit])

      expect(unit.metadata[:data_transformations]).not_to be_empty
    end

    it 'sets empty array when no transformations found' do
      unit = make_unit(
        identifier: 'Foo#noop',
        source_code: 'def noop; 42; end'
      )

      analyzer.annotate([unit])

      expect(unit.metadata[:data_transformations]).to eq([])
    end

    it 'does not modify other metadata' do
      unit = make_unit(
        identifier: 'Foo#bar',
        source_code: 'def bar; User.new; end'
      )
      unit.metadata[:existing_key] = 'preserved'

      analyzer.annotate([unit])

      expect(unit.metadata[:existing_key]).to eq('preserved')
    end
  end
end
