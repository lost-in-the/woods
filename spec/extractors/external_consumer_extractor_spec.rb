# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'woods'
require 'woods/extractors/external_consumer_extractor'

RSpec.describe Woods::Extractors::ExternalConsumerExtractor do
  include_context 'extractor setup'

  let(:catalog_class) { Woods::Extractors::TableCatalog }
  let(:catalog) do
    catalog_class.new([catalog_class::Table.new(name: 'products', models: ['Product']),
                       catalog_class::Table.new(name: 'orders', models: []),
                       catalog_class::Table.new(name: 'carts', models: ['Cart'])])
  end
  let(:configuration) { Woods::Configuration.new }

  before { allow(Woods).to receive(:configuration).and_return(configuration) }

  def units
    described_class.new(table_catalog: catalog).extract_all
  end

  describe '#extract_all' do
    it 'emits nothing for an application that declares nothing' do
      expect(units).to eq([])
    end

    it 'emits one external_consumer unit per declared application, sorted' do
      configuration.external_table_consumers = { 'storefront' => %w[products orders], 'reporting' => %w[orders] }

      expect(units.map(&:type).uniq).to eq([:external_consumer])
      expect(units.map(&:identifier)).to eq(%w[external:reporting external:storefront])
    end

    it 'links each declared table to its table unit, sorted' do
      configuration.external_table_consumers = { 'storefront' => %w[products orders] }

      expect(units.first.dependencies).to eq(
        [{ type: :database_table, target: 'table:orders', via: :reads_table },
         { type: :database_table, target: 'table:products', via: :reads_table }]
      )
    end

    it 'records the declaration as declared, with a table that no longer exists listed and unlinked' do
      configuration.external_table_consumers = { 'storefront' => %w[products retired_things] }

      unit = units.first

      expect(unit.metadata).to include(consumer: 'storefront', declared: true, tables: %w[products retired_things],
                                       tables_missing: ['retired_things'], declared_in: ['configuration'])
      expect(unit.dependencies.map { |dep| dep[:target] }).to eq(['table:products'])
      expect(unit.file_path).to be_nil
    end

    it 'links the table in every database that has one of that name' do
      multi = catalog_class.new([catalog_class::Table.new(name: 'orders', database: 'primary', qualified: true),
                                 catalog_class::Table.new(name: 'orders', database: 'billing', qualified: true)])
      configuration.external_table_consumers = { 'reporting' => %w[orders] }

      unit = described_class.new(table_catalog: multi).extract_all.first

      expect(unit.dependencies.map { |dep| dep[:target] }).to eq(%w[table:billing.orders table:primary.orders])
    end

    it 'describes the declaration in the unit source' do
      configuration.external_table_consumers = { 'storefront' => %w[products] }

      expect(units.first.source_code).to include('External consumer: storefront', 'declared', 'products')
    end

    context 'with a declared file' do
      before { configuration.external_table_consumers_path = 'config/woods/external_consumers.yml' }

      it 'reads consumers from the file and points the unit at it' do
        path = create_file('config/woods/external_consumers.yml', "storefront:\n  - products\n  - carts\n")

        unit = units.first

        expect(unit.identifier).to eq('external:storefront')
        expect(unit.file_path).to eq(path)
        expect(unit.metadata[:declared_in]).to eq(['config/woods/external_consumers.yml'])
        expect(unit.dependencies.map { |dep| dep[:target] }).to eq(%w[table:carts table:products])
      end

      it 'merges a consumer declared in both places' do
        create_file('config/woods/external_consumers.yml', "storefront:\n  - carts\n")
        configuration.external_table_consumers = { 'storefront' => %w[products] }

        unit = units.first

        expect(unit.metadata[:tables]).to eq(%w[carts products])
        expect(unit.metadata[:declared_in]).to eq(['config/woods/external_consumers.yml', 'configuration'])
      end

      it 'treats a missing file as declaring nothing' do
        configuration.external_table_consumers = { 'reporting' => %w[orders] }

        expect(units.map(&:identifier)).to eq(['external:reporting'])
      end

      it 'emits nothing and reports the failure when the file is malformed' do
        create_file('config/woods/external_consumers.yml', "storefront: products\n")
        configuration.external_table_consumers = { 'reporting' => %w[orders] }
        extractor = described_class.new(table_catalog: catalog)

        expect(extractor.extract_all).to eq([])
        expect(Woods::SourceInputs::ConsumerErrors.failed?(extractor)).to be(true)
      end

      it 'refuses YAML that is not plain data' do
        create_file('config/woods/external_consumers.yml', "storefront: !ruby/object:Object {}\n")
        extractor = described_class.new(table_catalog: catalog)

        expect(extractor.extract_all).to eq([])
        expect(Woods::SourceInputs::ConsumerErrors.failed?(extractor)).to be(true)
      end
    end
  end

  describe '.trigger_path?' do
    it 'fires only on the declared file' do
      configuration.external_table_consumers_path = 'config/woods/external_consumers.yml'

      expect(described_class.trigger_path?('config/woods/external_consumers.yml')).to be(true)
      expect(described_class.trigger_path?('config/woods/other.yml')).to be(false)
    end

    it 'never fires when no file is declared' do
      expect(described_class.trigger_path?('config/woods/external_consumers.yml')).to be(false)
    end
  end

  describe 'configuration' do
    it 'defaults to no consumers and no file' do
      expect(configuration.external_table_consumers).to eq({})
      expect(configuration.external_table_consumers_path).to be_nil
    end

    it 'normalizes names and tables to sorted, frozen strings' do
      configuration.external_table_consumers = { storefront: [:products, 'orders', 'orders'] }

      expect(configuration.external_table_consumers).to eq('storefront' => %w[orders products])
      expect(configuration.external_table_consumers).to be_frozen
    end

    [
      ['a non-Hash', %w[storefront]],
      ['a Proc', -> { {} }],
      ['an empty consumer name', { '' => %w[orders] }],
      ['a non-Array table list', { 'storefront' => 'orders' }],
      ['a Proc in a table list', { 'storefront' => [-> { 'orders' }] }],
      ['an empty table name', { 'storefront' => [''] }]
    ].each do |label, value|
      it "rejects #{label} at assignment and keeps the previous value" do
        configuration.external_table_consumers = { 'reporting' => %w[orders] }

        expect { configuration.external_table_consumers = value }.to raise_error(Woods::ConfigurationError)
        expect(configuration.external_table_consumers).to eq('reporting' => %w[orders])
      end
    end

    ['/etc/consumers.yml', '../consumers.yml', '', 42].each do |value|
      it "rejects the file path #{value.inspect}" do
        expect { configuration.external_table_consumers_path = value }.to raise_error(Woods::ConfigurationError)
      end
    end

    it 'accepts nil to clear the file path' do
      configuration.external_table_consumers_path = 'config/consumers.yml'
      configuration.external_table_consumers_path = nil

      expect(configuration.external_table_consumers_path).to be_nil
    end
  end
end
