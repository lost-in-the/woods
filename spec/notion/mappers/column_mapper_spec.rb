# frozen_string_literal: true

require 'spec_helper'
require 'codebase_index/notion/mappers/column_mapper'

RSpec.describe CodebaseIndex::Notion::Mappers::ColumnMapper do
  subject(:mapper) { described_class.new }

  let(:string_column) do
    { 'name' => 'email', 'type' => 'string', 'null' => false, 'limit' => 255, 'default' => nil }
  end

  let(:integer_column) do
    { 'name' => 'age', 'type' => 'integer', 'null' => true, 'default' => '0' }
  end

  let(:boolean_column) do
    { 'name' => 'active', 'type' => 'boolean', 'null' => false, 'default' => 'true' }
  end

  let(:datetime_column) do
    { 'name' => 'created_at', 'type' => 'datetime', 'null' => false }
  end

  let(:decimal_column) do
    { 'name' => 'price', 'type' => 'decimal', 'null' => true, 'default' => '0.0' }
  end

  let(:validations) do
    [
      { 'attribute' => 'email', 'type' => 'presence' },
      { 'attribute' => 'email', 'type' => 'uniqueness', 'options' => { 'scope' => 'org_id' } },
      { 'attribute' => 'name', 'type' => 'presence' },
      { 'attribute' => 'age', 'type' => 'numericality', 'options' => { 'greater_than' => 0 } }
    ]
  end

  describe '#map' do
    context 'with a string column with validations' do
      let(:result) do
        mapper.map(string_column, model_identifier: 'User', validations: validations)
      end

      it 'sets Column Name as title' do
        expect(result['Column Name']).to eq({ title: [{ text: { content: 'email' } }] })
      end

      it 'sets Data Type as select' do
        expect(result['Data Type']).to eq({ select: { name: 'string' } })
      end

      it 'sets Nullable as checkbox' do
        expect(result['Nullable']).to eq({ checkbox: false })
      end

      it 'sets Default Value when nil' do
        expect(result['Default Value'][:rich_text].first[:text][:content]).to eq('')
      end

      it 'matches validations for the column' do
        rules = result['Validation Rules'][:rich_text].first[:text][:content]
        expect(rules).to include('presence')
        expect(rules).to include('uniqueness')
      end

      it 'does not include validations for other columns' do
        rules = result['Validation Rules'][:rich_text].first[:text][:content]
        expect(rules).not_to include('numericality')
      end
    end

    context 'with an integer column' do
      let(:result) do
        mapper.map(integer_column, model_identifier: 'User', validations: validations)
      end

      it 'sets Data Type' do
        expect(result['Data Type']).to eq({ select: { name: 'integer' } })
      end

      it 'sets Nullable to true' do
        expect(result['Nullable']).to eq({ checkbox: true })
      end

      it 'sets Default Value' do
        expect(result['Default Value'][:rich_text].first[:text][:content]).to eq('0')
      end

      it 'matches numericality validation' do
        rules = result['Validation Rules'][:rich_text].first[:text][:content]
        expect(rules).to include('numericality')
      end
    end

    context 'with a boolean column' do
      let(:result) do
        mapper.map(boolean_column, model_identifier: 'User', validations: [])
      end

      it 'sets Data Type to boolean' do
        expect(result['Data Type']).to eq({ select: { name: 'boolean' } })
      end

      it 'sets Default Value' do
        expect(result['Default Value'][:rich_text].first[:text][:content]).to eq('true')
      end
    end

    context 'with no matching validations' do
      let(:result) do
        mapper.map(datetime_column, model_identifier: 'User', validations: validations)
      end

      it 'sets Validation Rules to None' do
        rules = result['Validation Rules'][:rich_text].first[:text][:content]
        expect(rules).to eq('None')
      end
    end

    context 'with parent_page_id for relation' do
      let(:result) do
        mapper.map(string_column, model_identifier: 'User', validations: [], parent_page_id: 'page-abc-123')
      end

      it 'sets Table as relation property' do
        expect(result['Table']).to eq({ relation: [{ id: 'page-abc-123' }] })
      end
    end

    context 'without parent_page_id' do
      let(:result) do
        mapper.map(string_column, model_identifier: 'User', validations: [])
      end

      it 'omits Table relation' do
        expect(result).not_to have_key('Table')
      end
    end

    context 'with empty validations array' do
      let(:result) do
        mapper.map(decimal_column, model_identifier: 'Product', validations: [])
      end

      it 'sets Validation Rules to None' do
        rules = result['Validation Rules'][:rich_text].first[:text][:content]
        expect(rules).to eq('None')
      end
    end
  end
end
