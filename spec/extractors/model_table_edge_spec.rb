# frozen_string_literal: true

require 'spec_helper'
require 'pathname'
require 'woods/extractors/model_extractor'

RSpec.describe Woods::Extractors::ModelExtractor, 'table edge' do
  let(:catalog_class) { Woods::Extractors::TableCatalog }
  let(:pool) { double('Pool') }
  let(:other_pool) { double('OtherPool') }

  before do
    stub_const('Rails', double('Rails', root: Pathname.new('/app'), logger: double(error: nil)))
  end

  def model_on(pool, table)
    double('Model', name: 'Widget', table_name: table, connection_pool: pool, module_parent: Object,
                    reflect_on_all_associations: [], included_modules: [],
                    singleton_class: double('SC', included_modules: []))
  end

  def table_edges(catalog, model)
    extractor = described_class.new(table_catalog: catalog)
    allow(extractor).to receive(:source_file_for).and_return(nil)
    extractor.send(:extract_dependencies, model, nil).select { |dep| dep[:type] == :database_table }
  end

  it 'links a model to the unit of the table it reads' do
    catalog = catalog_class.new([catalog_class::Table.new(name: 'widgets', models: ['Widget'], pool: pool)])

    expect(table_edges(catalog, model_on(pool, 'widgets'))).to eq(
      [{ type: :database_table, target: 'table:widgets', via: :table }]
    )
  end

  it 'targets the table on the model own database when two databases share the name' do
    catalog = catalog_class.new(
      [catalog_class::Table.new(name: 'widgets', database: 'primary', qualified: true, pool: other_pool),
       catalog_class::Table.new(name: 'widgets', database: 'billing', qualified: true, pool: pool)]
    )

    expect(table_edges(catalog, model_on(pool, 'widgets')).map { |dep| dep[:target] }).to eq(['table:billing.widgets'])
  end

  it 'emits no table edge when the name is not a live table' do
    catalog = catalog_class.new([catalog_class::Table.new(name: 'gadgets', models: [], pool: pool)])

    expect(table_edges(catalog, model_on(pool, 'widget_report_view'))).to eq([])
  end
end
