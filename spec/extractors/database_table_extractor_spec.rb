# frozen_string_literal: true

require 'spec_helper'
require 'woods/extracted_unit'
require 'woods/extractors/database_table_extractor'

RSpec.describe Woods::Extractors::DatabaseTableExtractor do
  include_context 'extractor setup'

  let(:catalog_class) { Woods::Extractors::TableCatalog }

  def column(name, type, sql_type, null: true, default: nil, default_function: nil)
    double("Column(#{name})", name: name, type: type, sql_type: sql_type, null: null, default: default,
                              default_function: default_function)
  end

  def index(name, columns, unique: false)
    double("Index(#{name})", name: name, columns: columns, unique: unique)
  end

  def foreign_key(from, to, column, name: nil, primary_key: 'id')
    double("ForeignKey(#{from}->#{to})", from_table: from, to_table: to, column: column, name: name,
                                         primary_key: primary_key)
  end

  # A pool whose connection answers schema questions from plain hashes.
  def pool_for(schema)
    connection = double('Connection', supports_foreign_keys?: true)
    { columns: nil, indexes: [], foreign_keys: [], primary_keys: ['id'] }.each do |reader, default|
      allow(connection).to receive(reader) { |table| schema.fetch(table).fetch(reader, default) }
    end
    pool = double('Pool')
    allow(pool).to receive(:with_connection).and_yield(connection)
    pool
  end

  def catalog_for(schema, models: {}, database: 'primary', qualified: false)
    pool = pool_for(schema)
    catalog_class.new(schema.keys.map do |name|
      catalog_class::Table.new(name: name, database: database, models: models.fetch(name, []),
                               qualified: qualified, pool: pool)
    end)
  end

  let(:schema) do
    {
      'widgets' => {
        columns: [column('id', :integer, 'bigint', null: false),
                  column('name', :string, 'varchar(255)', default: 'unnamed'),
                  column('created_at', :datetime, 'datetime', null: false, default_function: 'CURRENT_TIMESTAMP')],
        indexes: [index('index_widgets_on_name', ['name'], unique: true),
                  index('index_widgets_on_created_at', ['created_at'])]
      },
      'ledger_entries' => {
        columns: [column('id', :integer, 'bigint', null: false), column('widget_id', :integer, 'bigint')],
        foreign_keys: [foreign_key('ledger_entries', 'widgets', 'widget_id', name: 'fk_rails_1'),
                       foreign_key('ledger_entries', 'ledger_entries', 'parent_id'),
                       foreign_key('ledger_entries', 'elsewhere', 'other_id')]
      }
    }
  end

  let(:units) do
    described_class.new(table_catalog: catalog_for(schema, models: { 'widgets' => ['Widget'] })).extract_all
  end

  def unit(identifier)
    units.find { |candidate| candidate.identifier == identifier }
  end

  describe '#extract_all' do
    it 'emits one database_table unit per live table' do
      expect(units.map(&:type).uniq).to eq([:database_table])
      expect(units.map(&:identifier)).to eq(%w[table:ledger_entries table:widgets])
    end

    it 'records columns in schema order with type, nullability and default presence only' do
      expect(unit('table:widgets').metadata[:columns]).to eq(
        [{ name: 'id', type: 'integer', sql_type: 'bigint', null: false, has_default: false },
         { name: 'name', type: 'string', sql_type: 'varchar(255)', null: true, has_default: true },
         { name: 'created_at', type: 'datetime', sql_type: 'datetime', null: false, has_default: true }]
      )
    end

    it 'records the primary key and sorted indexes' do
      metadata = unit('table:widgets').metadata

      expect(metadata[:primary_key]).to eq('id')
      expect(metadata[:indexes]).to eq(
        [{ name: 'index_widgets_on_created_at', columns: ['created_at'], unique: false },
         { name: 'index_widgets_on_name', columns: ['name'], unique: true }]
      )
    end

    it 'keeps a composite primary key as a list and an absent one as nil' do
      schema['widgets'][:primary_keys] = %w[region_id id]
      schema['ledger_entries'][:primary_keys] = []

      expect(unit('table:widgets').metadata[:primary_key]).to eq(%w[region_id id])
      expect(unit('table:ledger_entries').metadata[:primary_key]).to be_nil
    end

    it 'names the owning model and flags a table without one' do
      expect(unit('table:widgets').metadata).to include(model: 'Widget', models: ['Widget'], model_less: false)
      expect(unit('table:ledger_entries').metadata).to include(model: nil, models: [], model_less: true)
    end

    it 'records the table and database names' do
      expect(unit('table:widgets').metadata).to include(table_name: 'widgets', database: 'primary')
    end

    it 'records foreign keys sorted by column' do
      expect(unit('table:ledger_entries').metadata[:foreign_keys]).to eq(
        [{ from_table: 'ledger_entries', to_table: 'elsewhere', column: 'other_id', primary_key: 'id', name: nil },
         { from_table: 'ledger_entries', to_table: 'ledger_entries', column: 'parent_id', primary_key: 'id',
           name: nil },
         { from_table: 'ledger_entries', to_table: 'widgets', column: 'widget_id', primary_key: 'id',
           name: 'fk_rails_1' }]
      )
    end

    it 'links foreign keys to live table units only, never to itself' do
      expect(unit('table:ledger_entries').dependencies).to eq(
        [{ type: :database_table, target: 'table:widgets', via: :foreign_key }]
      )
      expect(unit('table:widgets').dependencies).to eq([])
    end

    it 'targets the foreign table in the same database when identifiers are qualified' do
      catalog = catalog_for(schema, qualified: true)
      entry = described_class.new(table_catalog: catalog).extract_all
                             .find { |candidate| candidate.identifier == 'table:primary.ledger_entries' }

      expect(entry.dependencies).to eq(
        [{ type: :database_table, target: 'table:primary.widgets', via: :foreign_key }]
      )
    end

    it 'renders a readable schema summary as the unit source' do
      source = unit('table:ledger_entries').source_code

      expect(source).to include('Table: ledger_entries')
      expect(source).to include('Model: none')
      expect(source).to include('widget_id')
      expect(source).to include('widget_id -> widgets.id')
    end

    it 'has no file path, because the live schema is the source' do
      expect(units.map(&:file_path)).to eq([nil, nil])
    end

    it 'tolerates an adapter without foreign key support' do
      pool = double('Pool')
      connection = double('Connection', supports_foreign_keys?: false, columns: [], indexes: [], primary_keys: [])
      allow(pool).to receive(:with_connection).and_yield(connection)
      catalog = catalog_class.new([catalog_class::Table.new(name: 'widgets', models: [], pool: pool)])

      expect(described_class.new(table_catalog: catalog).extract_all.first.metadata[:foreign_keys]).to eq([])
    end

    it 'skips a table whose schema cannot be read and reports the failure' do
      schema['widgets'][:columns] = nil
      extractor = described_class.new(table_catalog: catalog_for(schema))

      expect(extractor.extract_all.map(&:identifier)).to eq(['table:ledger_entries'])
      expect(Woods::SourceInputs::ConsumerErrors.failed?(extractor)).to be(true)
    end

    it 'returns nothing when no database is connected' do
      expect(described_class.new(table_catalog: catalog_class.new([])).extract_all).to eq([])
    end
  end

  describe '.trigger_path?' do
    it 'fires on schema dumps, migrations and model files' do
      %w[db/schema.rb db/structure.sql db/billing_schema.rb db/billing_structure.sql
         db/migrate/20240101000000_create_widgets.rb db/migrate/archive/20200101000000_create_parts.rb
         app/models/widget.rb app/models/ledger/entry.rb].each do |path|
        expect(described_class.trigger_path?(path)).to be(true), path
      end
    end

    it 'stays quiet for everything else' do
      %w[db/seeds.rb db/migrate/notes.txt packs/ledger/app/models/ledger/entry.rb
         db/billing_migrate/20240101000000_create_invoices.rb db/views/report_v01.sql
         app/services/widget_service.rb app/models/widget.yml
         lib/db/schema.rb config/schema.rb].each do |path|
        expect(described_class.trigger_path?(path)).to be(false), path
      end
    end
  end
end
