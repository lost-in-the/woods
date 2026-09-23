# frozen_string_literal: true

require 'spec_helper'
require 'pathname'
require 'tmpdir'
require 'fileutils'
require 'woods/extractor'

RSpec.describe Woods::Extractor, 'standalone module reconciliation' do
  include_context 'isolated Woods runtime'

  let(:root) { Pathname.new(Dir.mktmpdir('woods_module_reconcile')) }
  let(:extractor) { described_class.new(output_dir: root.join('index')) }
  let(:path) { root.join('app/models/shared.rb').to_s }
  let(:concerns) { double('ConcernExtractor', runtime_model_mixins: {}, conventional_concern_path?: false) }
  let(:poros) { double('PoroExtractor', standalone_modules: {}) }

  before do
    stub_const('Rails', double('Rails', root: root, logger: double('Logger').as_null_object))
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, 'module Shared; def value; end; end')
    extractor.instance_variable_set(:@incremental_extractors, { concerns: concerns, poros: poros })
    extractor.instance_variable_set(:@eager_load_complete, false)
  end

  after { FileUtils.rm_rf(root) }

  def unit(identifier = 'Shared', type: :poro, module_kind: true)
    value = Woods::ExtractedUnit.new(type: type, identifier: identifier, file_path: path)
    value.metadata[:ruby_kind] = 'module' if module_kind
    value
  end

  def persist(value)
    extractor.send(:register_and_write, value.type == :poro ? :poros : :concerns, [value], Set.new)
  end

  def reconcile
    extractor.send(:reconcile_model_mixins, Set.new)
  end

  it 'uses plural extraction when following transitive PORO dependents' do
    expect(described_class::FILE_BASED.fetch(:poro)).to eq(:extract_poro_units)
  end

  it 'keeps an absent module through partial discovery and wholesale refresh' do
    persist(unit)
    allow(poros).to receive(:extract_all).and_return([])
    reconcile
    extractor.send(:replace_type_wholesale, :poros, Set.new)
    expect(extractor.dependency_graph.node_types('Shared')).to eq([:poro])
  end

  %i[poro concern].each do |type|
    it "does not relocate a retained #{type} owner during partial wholesale discovery" do
      extractor.dependency_graph.register(unit(type: type))
      replacement = unit(type: type)
      replacement.file_path = root.join('app/models/replacement.rb').to_s
      File.write(replacement.file_path, 'module Shared; def value; end; end')
      key, consumer = type == :poro ? [:poros, poros] : [:concerns, concerns]
      allow(consumer).to receive(:extract_all).and_return([replacement])
      expect { extractor.send(:replace_type_wholesale, key, Set.new) }
        .to raise_error(Woods::IdentityCollisionError, /collision/)
      expect(extractor.dependency_graph.node('Shared', type: type)[:file_path]).to eq(path)
    end
  end

  it 'removes a standalone module when positive concern ownership is discovered on a partial boot' do
    persist(unit)
    persist(unit('Sibling'))
    allow(concerns).to receive(:runtime_model_mixins).and_return(path => [double(name: 'Shared')])
    allow(concerns).to receive(:extract_model_mixin_file).with(path).and_return([unit(type: :concern)])
    reconcile
    expect(extractor.dependency_graph.node_types('Shared')).to eq([:concern])
    expect(extractor.dependency_graph.node_types('Sibling')).to eq([:poro])
  end

  it 'allows positive concern ownership to prune a former module from a changed shared file on a partial boot' do
    persist(unit)
    allow(concerns).to receive(:runtime_model_mixins).and_return(path => [double(name: 'Shared')])
    extractor.instance_variable_set(:@source_inputs, double('Session', source_identity: 'changed'))
    extractor.instance_variable_set(:@source_reference_baseline,
                                    'files' => { 'app/models/shared.rb' => { 'identity' => 'previous' } })
    expect(extractor.send(:retain_partial_module?, 'Shared', :poro)).to be(false)
  end

  it 'does not mistake a class PORO with the same identifier for a standalone module' do
    persist(unit(module_kind: false))
    allow(concerns).to receive(:runtime_model_mixins).and_return(path => [double(name: 'Shared')])
    allow(concerns).to receive(:extract_model_mixin_file).with(path).and_return([unit(type: :concern)])
    reconcile
    expect(extractor.dependency_graph.node_types('Shared')).to contain_exactly(:poro, :concern)
  end

  it 'keeps a retained concern authoritative when includers are absent from a partial boot' do
    persist(unit(type: :concern))
    allow(poros).to receive(:standalone_modules).and_return(path => [unit])
    allow(poros).to receive(:extract_all).and_return([unit])
    allow(concerns).to receive(:extract_all).and_return([])
    extractor.send(:replace_type_wholesale, :poros, Set.new)
    extractor.send(:replace_type_wholesale, :concerns, Set.new)
    reconcile
    expect(extractor.dependency_graph.node_types('Shared')).to eq([:concern])
  end

  it 'does not replace the consumption ledger for retained runtime units on a partial refresh' do
    persist(unit)
    allow(poros).to receive(:extract_all).and_return([])
    session = double('Session', unverified: nil, source_identity: 'captured')
    extractor.instance_variable_set(:@source_reference_baseline,
                                    'files' => { 'app/models/shared.rb' => { 'identity' => 'captured' } })
    extractor.instance_variable_set(:@source_inputs, session)
    expect(session).not_to receive(:consume_extractor)
    extractor.send(:replace_type_wholesale, :poros, Set.new)
  end
end
