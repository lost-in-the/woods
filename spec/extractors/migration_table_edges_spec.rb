# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'active_support/core_ext/string/inflections'
require 'woods/extractors/migration_extractor'

RSpec.describe Woods::Extractors::MigrationExtractor, 'table edges' do
  include_context 'extractor setup'

  let(:catalog_class) { Woods::Extractors::TableCatalog }

  def table(name, model: nil, database: nil, qualified: false)
    catalog_class::Table.new(name: name, database: database, models: Array(model), qualified: qualified)
  end

  let(:catalog) do
    catalog_class.new([table('widgets', model: 'Widget'), table('ledger_entries'), table('owners', model: 'Owner'),
                       table('parts', model: 'Part'), table('parts_widgets')])
  end

  def extract(body, name: 'ChangeThings', catalog: self.catalog)
    path = create_file("db/migrate/20240101000000_#{name.underscore}.rb", <<~RUBY)
      class #{name} < ActiveRecord::Migration[7.1]
        def change
      #{body.gsub(/^/, '    ')}
        end
      end
    RUBY
    described_class.new(table_catalog: catalog).extract_migration_file(path)
  end

  def edges(unit, via)
    unit.dependencies.select { |dep| dep[:via] == via }.map { |dep| [dep[:type], dep[:target]] }
  end

  it 'points at the table unit of every table it changes' do
    unit = extract("add_column :widgets, :color, :string\nadd_index :ledger_entries, :widget_id")

    expect(edges(unit, :migrates)).to contain_exactly([:database_table, 'table:ledger_entries'],
                                                      [:database_table, 'table:widgets'])
  end

  it 'keeps the model edge only for a table a model owns today' do
    unit = extract("add_column :widgets, :color, :string\nadd_column :ledger_entries, :memo, :string")

    expect(edges(unit, :table_name)).to eq([[:model, 'Widget']])
  end

  it 'takes the model name from the table owner, not from the table name' do
    renamed = catalog_class.new([table('ledger_entries', model: 'Accounting::Posting')])

    unit = extract('add_column :ledger_entries, :memo, :string', catalog: renamed)

    expect(edges(unit, :table_name)).to eq([[:model, 'Accounting::Posting']])
  end

  it 'emits no edge for a table that no longer exists, and lists it' do
    unit = extract("drop_table :retired_things\nadd_column :widgets, :color, :string")

    expect(unit.dependencies.map { |dep| dep[:target] }).not_to include('RetiredThing', 'table:retired_things')
    expect(unit.metadata[:tables_unresolved]).to eq(['retired_things'])
  end

  it 'reads string and parenthesized table names' do
    unit = extract(%(add_column "widgets", :color, :string\ncreate_table(:ledger_entries) { |t| t.string :memo }))

    expect(unit.metadata[:tables_affected]).to contain_exactly('widgets', 'ledger_entries')
  end

  it 'links a reference to the referenced table and to its model' do
    unit = extract('add_reference :widgets, :owner, foreign_key: true')

    expect(unit.metadata[:tables_referenced]).to eq(['owners'])
    expect(edges(unit, :migrates)).to include([:database_table, 'table:owners'])
    expect(edges(unit, :reference)).to eq([[:model, 'Owner']])
  end

  it 'drops a reference whose table does not exist, such as a polymorphic or aliased one' do
    unit = extract('add_reference :widgets, :holder, polymorphic: true')

    expect(edges(unit, :reference)).to eq([])
    expect(unit.metadata[:tables_unresolved]).to eq(['holders'])
  end

  it 'links both tables of a foreign key, including an explicit to_table' do
    unit = extract("add_foreign_key :ledger_entries, :widgets\nadd_reference :parts, :maker, " \
                   'foreign_key: { to_table: :owners }')

    expect(unit.metadata[:tables_referenced]).to include('widgets', 'owners')
    expect(edges(unit, :migrates)).to include([:database_table, 'table:widgets'], [:database_table, 'table:owners'])
  end

  it 'links a join table and the two tables it joins' do
    unit = extract('create_join_table :widgets, :parts')

    expect(unit.metadata[:tables_affected]).to eq(['parts_widgets'])
    expect(edges(unit, :migrates)).to contain_exactly([:database_table, 'table:parts'],
                                                      [:database_table, 'table:parts_widgets'],
                                                      [:database_table, 'table:widgets'])
  end

  it 'points at the table in every database that has one of that name' do
    multi = catalog_class.new([table('widgets', model: 'Widget', database: 'primary', qualified: true),
                               table('widgets', database: 'billing', qualified: true)])

    unit = extract('add_column :widgets, :color, :string', catalog: multi)

    expect(edges(unit, :migrates)).to eq([[:database_table, 'table:billing.widgets'],
                                          [:database_table, 'table:primary.widgets']])
    expect(edges(unit, :table_name)).to eq([[:model, 'Widget']])
  end

  it 'never links the Rails bookkeeping tables or reports them unresolved' do
    unit = extract('create_table(:schema_migrations) { |t| t.string :version }')

    expect(unit.dependencies).to eq([])
    expect(unit.metadata[:tables_unresolved]).to eq([])
  end

  it 'emits the same dependencies in the same order on every run' do
    body = "add_reference :widgets, :owner\nadd_column :parts, :sku, :string\nadd_index :ledger_entries, :memo"

    expect(extract(body).dependencies).to eq(extract(body).dependencies)
    expect(edges(extract(body), :migrates).map(&:last)).to eq(
      %w[table:ledger_entries table:owners table:parts table:widgets]
    )
  end
end
