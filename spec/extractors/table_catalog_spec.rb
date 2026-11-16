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

  describe '#ownership_facts' do
    let(:primary) { pool_double('primary', %w[widgets ledger_entries]) }

    it 'maps each table identifier to its owning models' do
      catalog = described_class.from_runtime(connection_classes: [model_double('Widget', 'widgets', primary)])

      expect(catalog.ownership_facts).to eq('table:ledger_entries' => [], 'table:widgets' => ['Widget'])
    end

    it 'changes when ownership moves' do
      owned = described_class.from_runtime(connection_classes: [model_double('Widget', 'widgets', primary)])
      moved = described_class.from_runtime(connection_classes: [model_double('Widget', 'ledger_entries', primary)])

      expect(moved.ownership_facts).not_to eq(owned.ownership_facts)
    end

    it 'changes every identifier once a second database is connected' do
      billing = pool_double('billing', %w[widgets])
      single = described_class.from_runtime(connection_classes: [model_double('Widget', 'widgets', primary)])
      pair = described_class.from_runtime(connection_classes: [model_double('Widget', 'widgets', primary),
                                                               model_double('Bill', 'widgets', billing)])

      expect(pair.ownership_facts.keys & single.ownership_facts.keys).to be_empty
    end
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

  describe '.schema_readability' do
    def listing_pool(name, data_sources, replica: false)
      connection = double("Connection(#{name})", data_sources: data_sources)
      pool = double("Pool(#{name})", db_config: double('DbConfig', name: name, replica?: replica))
      allow(pool).to receive(:with_connection).and_yield(connection)
      pool
    end

    def failing_pool(name, error)
      pool = double("Pool(#{name})", db_config: double('DbConfig', name: name, replica?: false))
      allow(pool).to receive(:with_connection).and_raise(error)
      pool
    end

    def states(classes)
      described_class.schema_readability(connection_classes: classes).map { |db| db.slice(:name, :state) }
    end

    it 'reads a database that lists a table its models read' do
      primary = listing_pool('primary', %w[widgets schema_migrations])

      expect(states([model_double('Widget', 'widgets', primary)]))
        .to eq([{ name: 'primary', state: 'readable' }])
    end

    it 'keeps a database readable when one model table is absent beside a table that exists' do
      primary = listing_pool('primary', %w[widgets])
      classes = [model_double('Widget', 'widgets', primary), model_double('Gadget', 'gadgets', primary)]

      expect(states(classes)).to eq([{ name: 'primary', state: 'readable' }])
    end

    it 'reports a database that holds only the Rails bookkeeping tables as empty' do
      primary = listing_pool('primary', %w[schema_migrations ar_internal_metadata])

      expect(states([model_double('Widget', 'widgets', primary)]))
        .to eq([{ name: 'primary', state: 'empty' }])
    end

    it 'counts a view as something the database holds' do
      primary = listing_pool('primary', %w[widget_totals])

      expect(states([model_double('WidgetTotal', 'widget_totals', primary)]).first[:state]).to eq('readable')
    end

    it 'reports a database whose listing raises as unreachable, with the error for the log' do
      primary = failing_pool('primary', StandardError.new('connection refused'))

      result = described_class.schema_readability(connection_classes: [model_double('Widget', 'widgets', primary)])

      expect(result.map { |db| db.slice(:name, :state) }).to eq([{ name: 'primary', state: 'unreachable' }])
      expect(result.first[:error]).to eq('StandardError: connection refused')
    end

    it 'reports a model with no connection pool as unreachable' do
      widget = model_double('Widget', 'widgets', nil)
      allow(widget).to receive(:connection_pool).and_raise(StandardError, 'No connection pool')

      expect(states([widget])).to eq([{ name: nil, state: 'unreachable' }])
    end

    it 'reports each database on its own when one of two is unreachable' do
      primary = listing_pool('primary', %w[widgets])
      billing = failing_pool('billing', StandardError.new('database not found'))
      classes = [model_double('Widget', 'widgets', primary), model_double('Invoice', 'invoices', billing)]

      expect(states(classes)).to eq([{ name: 'billing', state: 'unreachable' },
                                     { name: 'primary', state: 'readable' }])
    end

    it 'merges the pools on one database, reporting the worst of them' do
      readable = listing_pool('primary', %w[widgets])
      failing = failing_pool('primary', StandardError.new('database not found'))
      classes = [model_double('Widget', 'widgets', readable), model_double('Gadget', 'gadgets', failing)]

      expect(states(classes)).to eq([{ name: 'primary', state: 'unreachable' }])
    end

    it 'never asks a database that no concrete model reads through a writable pool' do
      unused = failing_pool('primary', StandardError.new('connection refused'))
      replica = failing_pool('primary_replica', StandardError.new('connection refused'))
      allow(replica.db_config).to receive(:replica?).and_return(true)
      classes = [model_double('ApplicationRecord', 'application_records', unused, abstract: true),
                 model_double('Widget::HABTM_Gadgets', 'gadgets_widgets', unused),
                 model_double(nil, 'widgets', unused),
                 model_double('Copy', 'widgets', replica)]

      expect(states(classes)).to eq([])
      expect(unused).not_to have_received(:with_connection)
    end

    it "never asks a database that only the framework's own models read" do
      unused = failing_pool('primary', StandardError.new('database not found'))
      bookkeeping = model_double('ActiveRecord::SchemaMigration', 'schema_migrations', unused)
      allow(Woods::Extractors::SourceOrigin).to receive(:constant_origin).and_call_original
      allow(Woods::Extractors::SourceOrigin).to receive(:constant_origin).with(bookkeeping).and_return('framework')

      expect(states([bookkeeping])).to eq([])
      expect(unused).not_to have_received(:with_connection)
    end

    it 'records nothing without Active Record classes' do
      expect(described_class.schema_readability(connection_classes: [])).to eq([])
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
