# frozen_string_literal: true

require 'spec_helper'
require 'woods/extractors/table_catalog'

RSpec.describe Woods::Extractors::TableCatalog do
  include_context 'extractor setup'

  def pool_double(name, tables, replica: false)
    connection = double("Connection(#{name})", tables: tables)
    pool = double("Pool(#{name})", db_config: double('DbConfig', name: name, replica?: replica))
    allow(pool).to receive(:with_connection).and_yield(connection)
    pool
  end

  def model_double(name, table, pool, base: nil, abstract: false)
    klass = double("Model(#{name})", name: name, table_name: table, connection_pool: pool,
                                     abstract_class?: abstract)
    allow(klass).to receive(:base_class).and_return(base || klass)
    klass
  end

  describe '.from_runtime' do
    let(:primary) { pool_double('primary', %w[widgets ledger_entries schema_migrations ar_internal_metadata]) }

    it 'lists every live table except the Rails bookkeeping tables, sorted' do
      catalog = described_class.from_runtime(connection_classes: [model_double('Widget', 'widgets', primary)])

      expect(catalog.tables.map(&:identifier)).to eq(%w[table:ledger_entries table:widgets])
    end

    it 'records the owning model and leaves a table nobody claims without one' do
      catalog = described_class.from_runtime(connection_classes: [model_double('Widget', 'widgets', primary)])

      expect(catalog.named('widgets').first.model).to eq('Widget')
      expect(catalog.named('ledger_entries').first.model).to be_nil
    end

    it 'prefers the inheritance root over its subclasses, then the first name' do
      root = model_double('Widget', 'widgets', primary)
      classes = [model_double('Gadget', 'widgets', primary, base: root), root,
                 model_double('Alias', 'widgets', primary)]

      table = described_class.from_runtime(connection_classes: classes).named('widgets').first

      expect(table.model).to eq('Alias')
      expect(table.models).to eq(%w[Alias Widget])
    end

    it 'ignores abstract, anonymous and has_and_belongs_to_many join classes as owners' do
      classes = [model_double('ApplicationRecord', 'widgets', primary, abstract: true),
                 model_double(nil, 'widgets', primary),
                 model_double('Widget::HABTM_Parts', 'widgets', primary)]

      expect(described_class.from_runtime(connection_classes: classes).named('widgets').first.model).to be_nil
    end

    it 'qualifies identifiers by database once a second database is connected' do
      billing = pool_double('billing', %w[widgets invoices])
      classes = [model_double('Widget', 'widgets', primary), model_double('Invoice', 'invoices', billing)]

      catalog = described_class.from_runtime(connection_classes: classes)

      expect(catalog.tables.map(&:identifier)).to eq(
        %w[table:billing.invoices table:billing.widgets table:primary.ledger_entries table:primary.widgets]
      )
      expect(catalog.named('widgets').map(&:database)).to eq(%w[billing primary])
      expect(catalog.named('widgets').map(&:model)).to eq([nil, 'Widget'])
    end

    it 'skips replica pools' do
      replica = pool_double('primary_replica', %w[widgets], replica: true)
      classes = [model_double('Widget', 'widgets', primary), model_double('Copy', 'widgets', replica)]

      catalog = described_class.from_runtime(connection_classes: classes)

      expect(catalog.tables.map(&:identifier)).to eq(%w[table:ledger_entries table:widgets])
    end

    it 'keeps identifiers qualified when a second database cannot be read' do
      broken = double('Pool(broken)', db_config: double('DbConfig', name: 'broken', replica?: false))
      allow(broken).to receive(:with_connection).and_raise(StandardError, 'connection refused')
      classes = [model_double('Widget', 'widgets', primary), model_double('Lost', 'lost', broken)]

      catalog = described_class.from_runtime(connection_classes: classes)

      expect(catalog.tables.map(&:identifier)).to eq(%w[table:primary.ledger_entries table:primary.widgets])
    end

    it 'resolves the table a model class reads, by its own connection pool' do
      billing = pool_double('billing', %w[widgets])
      widget = model_double('Widget', 'widgets', primary)
      copy = model_double('BillingWidget', 'widgets', billing)
      view_backed = model_double('Report', 'reports', primary)

      catalog = described_class.from_runtime(connection_classes: [widget, copy, view_backed])

      expect(catalog.for_model(widget).identifier).to eq('table:primary.widgets')
      expect(catalog.for_model(copy).identifier).to eq('table:billing.widgets')
      expect(catalog.for_model(view_backed)).to be_nil
    end

    it 'reads a database once when several classes hold their own pool on it' do
      own_pool = pool_double('primary', %w[widgets ledger_entries])
      widget = model_double('Widget', 'widgets', primary)
      entry = model_double('LedgerEntry', 'ledger_entries', own_pool)

      catalog = described_class.from_runtime(connection_classes: [widget, entry])

      expect(catalog.tables.map(&:identifier)).to eq(%w[table:ledger_entries table:widgets])
      expect(catalog.named('ledger_entries').first.model).to eq('LedgerEntry')
      expect(catalog.for_model(entry).identifier).to eq('table:ledger_entries')
    end
  end

  describe '.new' do
    it 'serves declared tables without a runtime, for extractors under test' do
      catalog = described_class.new([described_class::Table.new(name: 'widgets', models: ['Widget'])])

      expect(catalog.named('widgets').first.identifier).to eq('table:widgets')
      expect(catalog.named('missing')).to eq([])
    end
  end
end
