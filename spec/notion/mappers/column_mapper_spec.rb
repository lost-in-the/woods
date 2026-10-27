# frozen_string_literal: true

require 'spec_helper'
require 'woods/notion/mappers/column_mapper'

RSpec.describe Woods::Notion::Mappers::ColumnMapper do
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
    describe 'column default values' do
      let(:secret_column) do
        { 'name' => 'api_key', 'type' => 'string', 'null' => true,
          'default' => "sk_live_#{'a1B2' * 6}" }
      end

      def default_text(properties)
        properties['Default Value'][:rich_text].first[:text][:content]
      end

      it 'never sends the raw default by default' do
        expect(default_text(mapper.map(integer_column))).to eq('Has default')
        expect(default_text(mapper.map(secret_column))).to eq('Has default')
      end

      it 'appends the published digest when the column carries one' do
        column = integer_column.merge('default_digest' => 'abcdef0123456789')
        expect(default_text(mapper.map(column))).to eq('Has default (digest abcdef0123456789)')
      end

      it 'treats a false default as present' do
        column = { 'name' => 'flag', 'type' => 'boolean', 'null' => false, 'default' => 'false' }
        expect(default_text(mapper.map(column))).to eq('Has default')
      end

      context 'with include_defaults: true' do
        subject(:mapper) { described_class.new(include_defaults: true) }

        it 'sends the value' do
          expect(default_text(mapper.map(integer_column))).to eq('0')
        end

        it 'redacts credential-shaped values' do
          text = default_text(mapper.map(secret_column))
          expect(text).not_to include('sk_live_')
          expect(text).to include('[REDACTED]')
        end

        it 'sends an empty string when there is no default' do
          expect(default_text(mapper.map(string_column))).to eq('')
        end
      end
    end

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

      it 'leaves Default Value empty when the column has no default' do
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

      it 'reports that a default exists without sending its value' do
        expect(result['Default Value'][:rich_text].first[:text][:content]).to eq('Has default')
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

      it 'reports that a default exists without sending its value' do
        expect(result['Default Value'][:rich_text].first[:text][:content]).to eq('Has default')
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

    context 'with parent_page_ids for relation' do
      let(:result) do
        mapper.map(string_column, model_identifier: 'User', validations: [], parent_page_ids: ['page-abc-123'])
      end

      it 'sets Table as relation property' do
        expect(result['Table']).to eq({ relation: [{ id: 'page-abc-123' }] })
      end
    end

    # EXP-1. A physical table owned by several models (STI) gets one column
    # page whose relation names every owner — Notion relations are lists.
    context 'with several parent_page_ids' do
      let(:result) do
        mapper.map(string_column, model_identifier: 'User', validations: [],
                                  parent_page_ids: %w[page-user page-admin])
      end

      it 'lists every owning page in the given order' do
        expect(result['Table']).to eq({ relation: [{ id: 'page-user' }, { id: 'page-admin' }] })
      end
    end

    context 'without parent_page_ids' do
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

    context 'with a table name qualifier (#149)' do
      let(:result) do
        mapper.map(string_column, model_identifier: 'User', table_name: 'users', validations: [])
      end

      it 'qualifies the title as table.column' do
        expect(result['Column Name']).to eq({ title: [{ text: { content: 'users.email' } }] })
      end

      it 'leaves the remaining properties keyed on the bare column' do
        expect(result['Data Type']).to eq({ select: { name: 'string' } })
      end
    end

    context 'with a blank table name' do
      it 'falls back to the bare column name' do
        result = mapper.map(string_column, model_identifier: 'User', table_name: '', validations: [])
        expect(result['Column Name']).to eq({ title: [{ text: { content: 'email' } }] })
      end
    end

    context 'without a table name' do
      it 'keeps the bare column name as title' do
        result = mapper.map(string_column, model_identifier: 'User', validations: [])
        expect(result['Column Name']).to eq({ title: [{ text: { content: 'email' } }] })
      end
    end
  end
end
