# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'json'
require 'woods/extractor'

# An incremental run re-derives every unit in a change's blast radius, and
# most of them come out unchanged. The unchanged check runs before the
# Prism-walking table passes (method table, callback declaration sites, test
# examples), which derive only from what the check compares, so a retained
# unit skips them and keeps its published JSON.
RSpec.describe Woods::Extractor, 'unchanged re-derived units' do
  include_context 'isolated Woods runtime'

  let(:root) { Dir.mktmpdir('woods-unchanged') }
  let(:extractor) { described_class.new(output_dir: File.join(root, 'index')) }
  let(:source_inputs) { instance_double(Woods::SourceInputs::Session, consume_unit: nil, unverified: nil) }
  let(:source) { "class Invoice < ApplicationRecord\n  before_save :total\n\n  def total\n  end\nend\n" }
  let(:path) { File.join(root, 'app/models/invoice.rb') }
  let(:unit_path) { File.join(root, 'index/models', extractor.send(:collision_safe_filename, 'Invoice')) }

  before do
    stub_const('Rails', double('Rails', root: Pathname.new(root), logger: double('Logger').as_null_object))
    extractor.instance_variable_set(:@eager_load_complete, true)
    extractor.instance_variable_set(:@source_inputs, source_inputs)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, source)
  end

  after { FileUtils.rm_rf(root) }

  def unit(source_code: source, metadata: {})
    Woods::ExtractedUnit.new(type: :model, identifier: 'Invoice', file_path: path).tap do |unit|
      unit.source_code = source_code
      unit.metadata = { callbacks: [{ type: 'before_save', filter: 'total' }], table_name: 'invoices' }.merge(metadata)
    end
  end

  def register(unit)
    extractor.send(:register_and_write, :models, [unit], Set.new)
  end

  def published
    JSON.parse(File.read(unit_path))
  end

  # The baseline: a full registration, tables and all, as a published
  # generation carries it.
  before { register(unit) }

  it 'publishes the tables the first time' do
    expect(published['metadata']['methods'].map { |entry| entry['name'] }).to eq(['total'])
    expect(published['metadata']['callbacks'].first['declaration']).to include('line' => 2, 'end_line' => 2)
  end

  it 'skips the table passes and the write for a unit re-derived unchanged' do
    bytes = File.binread(unit_path)
    expect(Woods::MethodTable).not_to receive(:record)
    expect(Woods::CallbackSites).not_to receive(:record)
    expect(Woods::Extractors::TestExamples).not_to receive(:record)
    expect(extractor).not_to receive(:write_unit_file)

    written = register(unit)

    expect(written).to be_empty
    expect(File.binread(unit_path)).to eq(bytes)
    expect(extractor.instance_variable_get(:@retained_units)).to include(%w[model Invoice])
  end

  it 'still consumes the source paths of a unit it retains' do
    expect(source_inputs).to receive(:consume_unit).with(:models, path)

    register(unit)
  end

  it 'rewrites a unit whose source changed, with its tables' do
    changed = "#{source}# trailing comment\n"
    File.write(path, changed)
    expect(Woods::MethodTable).to receive(:record).and_call_original

    written = register(unit(source_code: changed))

    expect(written).to eq(Set.new(['Invoice']))
    expect(published['source_code']).to eq(changed)
    expect(published['metadata']['methods'].map { |entry| entry['name'] }).to eq(['total'])
  end

  it 'rewrites a unit whose only change is a metadata field no table pass writes' do
    written = register(unit(metadata: { table_name: 'ledger_invoices' }))

    expect(written).to eq(Set.new(['Invoice']))
    expect(published['metadata']['table_name']).to eq('ledger_invoices')
  end

  it 'rewrites a unit whose callback list changed' do
    written = register(unit(metadata: { callbacks: [] }))

    expect(written).to eq(Set.new(['Invoice']))
    expect(published['metadata']['callbacks']).to eq([])
  end
end
