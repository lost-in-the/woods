# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'woods/source_references/pass'
require 'woods/source_inputs/stable_reader'

RSpec.describe Woods::SourceReferences::Pass do
  let(:root) { '/reference-app' }
  let(:sources) do
    {
      'app/models/ref_caller.rb' => 'class RefCaller; def call; RefTarget.new; end; end',
      'app/models/ref_target.rb' => 'class RefTarget; end'
    }
  end
  let(:session) { double('Source session') }
  let(:collector) { Woods::SourceReferences::Collector.new }
  let(:units) { sources.keys.zip(%w[RefCaller RefTarget]).map { |path, id| unit(id, path) } }

  before do
    stub_const('RefCaller', Class.new)
    stub_const('RefTarget', Class.new)
    allow(session).to receive(:source_identity) { |path| sources.key?(path) ? Digest::SHA256.hexdigest(sources[path]) : nil }
    allow(session).to receive(:read_source) do |path|
      { 'path' => path, 'source' => sources.fetch(path), 'identity' => Digest::SHA256.hexdigest(sources.fetch(path)) }
    end
    allow(session).to receive(:consumed_source?).and_return(true)
  end

  def unit(id, path, type = 'poro')
    { 'identifier' => id, 'type' => type, 'file_path' => path, 'dependencies' => [],
      'metadata' => { 'git' => { 'commit_count' => 7 } }, 'extracted_at' => 'preserved' }
  end

  let(:policy) { Woods::SourceReferences::CallerPolicy.new }
  let(:extractor_keys) { { poro: :poros, lib: :lib, model: :models } }

  def run_pass(baseline: nil, refreshed: [], full: true, policy: self.policy)
    described_class.new(root: root, session: session, units: units, baseline: baseline,
                        refreshed: refreshed, full: full, collector: collector, policy: policy,
                        extractor_keys: extractor_keys).call
  end

  def edge(target = 'RefTarget')
    { 'type' => 'poro', 'target' => target, 'via' => 'code_reference' }
  end

  it 'adds a resolved edge using captured source while retaining other unit data' do
    result = run_pass
    expect(result.dependencies.fetch(%w[poro RefCaller])).to eq([edge])
    expect(units.first['dependencies']).to eq([])
    expect(result.cache['owners']).to include(hash_including('identifier' => 'RefCaller', 'added' => [edge]))
    expect(result.cache['files'].keys).to match_array(sources.keys)
  end

  it 'publishes selector evidence on admitted receivers without verifying method existence or changing edges' do
    sources['app/models/ref_caller.rb'] =
      'class RefCaller; RefTarget.missing; RefTarget.new.execute; consume(RefTarget); RefTarget; Missing.call; end'
    result = run_pass
    expect(RefTarget).not_to respond_to(:missing)
    expect(result.dependencies.fetch(%w[poro RefCaller])).to eq([edge])
    records = result.references.fetch(%w[poro RefCaller])
    expected = [
      { 'target' => 'RefTarget', 'method' => 'missing' }, { 'target' => 'RefTarget', 'method' => 'new' },
      { 'target' => 'RefTarget' }, { 'target' => 'RefTarget' }
    ]
    expect(records.map { |record| record.slice('target', 'method') }).to eq(expected)
    expect(records).to all(include('target_type' => 'poro', 'kind' => 'constant', 'confidence' => 'verified'))
    expect(result.cache['files']['app/models/ref_caller.rb']['analysis']['references'].last)
      .to include('name' => 'Missing', 'method' => 'call')
  end

  it 'tags a verified include, extend or prepend of a constant, without changing the edge or the kind' do
    sources['app/models/ref_caller.rb'] =
      'class RefCaller; include RefTarget; extend RefTarget; prepend RefTarget; RefTarget.new; end'
    result = run_pass
    expect(result.dependencies.fetch(%w[poro RefCaller])).to eq([edge])
    records = result.references.fetch(%w[poro RefCaller])
    expect(records.map { |record| record.values_at('mixin', 'method') })
      .to eq([['include', nil], ['extend', nil], ['prepend', nil], [nil, 'new']])
    expect(records).to all(include('kind' => 'constant', 'confidence' => 'verified'))
  end

  it 'does not tag a static span, which is not a verified reference' do
    sources['app/models/ref_caller.rb'] = 'class RefCaller; class << self; include RefTarget; end; end'
    records = run_pass.references.fetch(%w[poro RefCaller])
    expect(records).to contain_exactly(hash_including('confidence' => 'static'))
    expect(records.first).not_to have_key('mixin')
  end

  it 'publishes a static span for an indexed constant that runtime lookup cannot see, and no edge' do
    sources['app/models/ref_caller.rb'] = 'class RefCaller; class << self; def build; RefTarget.create; end; end; end'
    result = run_pass
    expect(result.dependencies.fetch(%w[poro RefCaller])).to eq([])
    expect(result.references.fetch(%w[poro RefCaller])).to eq([
                                                                { 'line' => 1, 'column' => 43, 'length' => 9,
                                                                  'method' => 'create',
                                                                  'file_path' => 'app/models/ref_caller.rb',
                                                                  'kind' => 'constant', 'target' => 'RefTarget',
                                                                  'target_type' => 'poro', 'confidence' => 'static' }
                                                              ])
  end

  it 'lists every lexical candidate of an unresolved spelling as ambiguous' do
    sources['app/models/admin/ref_target.rb'] = 'module Admin; class RefTarget; end; end'
    sources['app/models/ref_caller.rb'] = 'module Admin; class RefCaller; class << self; RefTarget; end; end; end'
    units.replace([unit('Admin::RefCaller', 'app/models/ref_caller.rb'), unit('RefTarget', 'app/models/ref_target.rb'),
                   unit('Admin::RefTarget', 'app/models/admin/ref_target.rb')])
    stub_const('Admin', Module.new)
    stub_const('Admin::RefCaller', Class.new)
    stub_const('Admin::RefTarget', Class.new)
    spans = run_pass.references.fetch(%w[poro Admin::RefCaller])
    expect(spans.map { |span| span.values_at('confidence', 'candidates') }).to eq([
                                                                                    ['ambiguous', [
                                                                                      { 'target' => 'Admin::RefTarget',
                                                                                        'target_type' => 'poro' },
                                                                                      { 'target' => 'RefTarget',
                                                                                        'target_type' => 'poro' }
                                                                                    ]]
                                                                                  ])
  end

  it 'publishes no candidate for a runtime target outside the index or for the owner itself' do
    sources['app/models/ref_caller.rb'] = 'class RefCaller; String.new; RefCaller.new; end'
    expect(run_pass.references.fetch(%w[poro RefCaller])).to eq([])
  end

  it 'publishes declaration spans the runtime metadata confirms, without edges' do
    sources['app/models/ref_caller.rb'] = <<~RUBY
      class RefCaller
        belongs_to :ref_target
        has_many :ghosts
        before_save :set_slug, :undeclared
        scope :recent, -> { where(x: 1) }
      end
    RUBY
    units.first.merge!('type' => 'model', 'metadata' => {
                         'associations' => [{ 'name' => 'ref_target', 'type' => 'belongs_to',
                                              'target' => 'RefTarget' }],
                         'callbacks' => [{ 'type' => 'before_save', 'filter' => 'set_slug' }],
                         'scopes' => [{ 'name' => 'recent', 'source' => 'scope :recent' }]
                       })
    result = run_pass
    expect(result.dependencies.fetch(%w[model RefCaller])).to eq([])
    expected = [
      { 'line' => 2, 'column' => 13, 'length' => 11, 'target' => 'RefTarget', 'target_type' => 'poro',
        'kind' => 'association', 'confidence' => 'verified' },
      { 'line' => 4, 'column' => 14, 'length' => 9, 'target' => 'RefCaller', 'target_type' => 'model',
        'kind' => 'callback_method', 'confidence' => 'verified', 'method' => 'set_slug' },
      { 'line' => 5, 'column' => 8, 'length' => 7, 'target' => 'RefCaller', 'target_type' => 'model',
        'kind' => 'scope', 'confidence' => 'verified', 'method' => 'recent' }
    ]
    expect(result.references.fetch(%w[model RefCaller]).map { |span| span.except('file_path') }).to eq(expected)
  end

  it 'keeps an inherited selector on the resolved receiver without attributing a method-definition owner' do
    parent = Class.new do
      def self.inherited_call
        raise 'must never execute'
      end
    end
    stub_const('RefTarget', Class.new(parent))
    sources['app/models/ref_caller.rb'] = 'class RefCaller; RefTarget.inherited_call; end'
    span = run_pass.references.fetch(%w[poro RefCaller]).fetch(0)
    expect(span).to include('target' => 'RefTarget', 'target_type' => 'poro', 'method' => 'inherited_call')
    expect(span.keys).to contain_exactly('line', 'column', 'length', 'file_path', 'target', 'target_type',
                                         'kind', 'confidence', 'method')
  end

  it 'retains duplicate verified occurrences independently of existing edges and their through annotation' do
    sources['app/models/ref_caller.rb'] = 'class RefCaller; RefTarget.new; RefTarget.new; end'
    scanner = edge.merge('type' => 'service', 'through' => 'call')
    units.first['dependencies'] = [scanner]
    result = run_pass
    expect(result.dependencies.fetch(%w[poro RefCaller])).to eq([scanner])
    spans = result.references.fetch(%w[poro RefCaller])
    expect(spans.map { |span| span.values_at('line', 'column', 'length') }).to eq([[1, 17, 9], [1, 32, 9]])
    expect(spans).to all(include('target' => 'RefTarget', 'target_type' => 'poro', 'kind' => 'constant',
                                 'confidence' => 'verified', 'file_path' => 'app/models/ref_caller.rb'))
  end

  it 'adds no second edge beside one the extractor annotated with the reaching methods' do
    annotated = edge.merge('through' => 'call')
    units.first['dependencies'] = [annotated]

    result = run_pass

    expect(result.dependencies.fetch(%w[poro RefCaller])).to eq([annotated])
    expect(result.cache['owners']).to include(hash_including('identifier' => 'RefCaller', 'added' => []))
  end

  it 'records target-only typed consumption without adding caller dependency rewrites' do
    units.last['type'] = 'component'
    result = run_pass(policy: Woods::SourceReferences::CallerPolicy.new(component: false))
    expect(result.cache['owners']).to include(include('identifier' => 'RefTarget', 'type' => 'component',
                                                      'added' => []))
    expect(result.dependencies).not_to have_key(%w[component RefTarget])
    expect(Woods::SourceReferences::Cache).to receive(:write).and_call_original
    Dir.mktmpdir do |dir|
      Woods::SourceReferences::Cache.write(File.join(dir, 'cache.json'), result.cache)
    end
  end

  it 'records the caller policy in the cache' do
    expect(run_pass.cache.fetch('callers')).to eq(policy.to_h)
  end

  it 'requires a rebuild when the caller policy differs from the one that produced the baseline' do
    initial = run_pass
    narrowed = Woods::SourceReferences::CallerPolicy.new(poro: %i[lib])
    expect { run_pass(baseline: initial.cache, full: false, policy: narrowed) }.to raise_error(
      Woods::SourceReferences::RebuildRequired, /source_reference_callers changed.*woods:extract/m
    )
  end

  it 'rebuilds from a full extraction whatever policy the baseline recorded' do
    initial = run_pass
    narrowed = Woods::SourceReferences::CallerPolicy.new(poro: %i[lib])
    result = run_pass(baseline: initial.cache, full: true, policy: narrowed)
    expect(result.cache.fetch('callers')).to eq(narrowed.to_h)
    expect(result.dependencies.fetch(%w[poro RefCaller])).to eq([])
  end

  context 'with a caller policy that narrows targets' do
    let(:policy) { Woods::SourceReferences::CallerPolicy.new(poro: %i[lib]) }

    it 'drops a verified edge to a target type the caller may not reference' do
      result = run_pass
      expect(result.dependencies.fetch(%w[poro RefCaller])).to eq([])
      expect(result.cache['owners']).to include(hash_including('identifier' => 'RefCaller', 'added' => []))
    end

    it 'keeps a verified edge to a permitted target type' do
      units.last['type'] = 'lib'
      expect(run_pass.dependencies.fetch(%w[poro RefCaller])).to eq([edge.merge('type' => 'lib')])
    end
  end

  context 'with a caller policy that excludes the caller type' do
    let(:policy) { Woods::SourceReferences::CallerPolicy.new(poro: false) }

    it 'leaves the unit out of the dependency rewrites and keeps its ownership record' do
      result = run_pass
      expect(result.dependencies).to be_empty
      expect(result.cache['owners']).to include(hash_including('identifier' => 'RefCaller', 'added' => []))
    end
  end

  it 'caches unresolved candidates so a new target updates an unchanged caller without parsing it again' do
    units.pop
    initial = run_pass
    expect(initial.dependencies.fetch(%w[poro RefCaller])).to be_empty
    units << unit('RefTarget', 'app/models/ref_target.rb')
    expect(collector).to receive(:call).with(sources.fetch('app/models/ref_target.rb')).once.and_call_original
    expect(collector).not_to receive(:call).with(sources.fetch('app/models/ref_caller.rb'))
    result = run_pass(baseline: initial.cache, refreshed: [%w[poro RefTarget]], full: false)
    expect(result.dependencies.fetch(%w[poro RefCaller])).to eq([edge])
    expect(result.references.fetch(%w[poro RefCaller]).first).to include('target_type' => 'poro', 'method' => 'new')
  end

  it 'withdraws only its own additions when a target disappears' do
    initial = run_pass
    units.first['dependencies'] = [edge, { 'type' => 'model', 'target' => 'Account', 'via' => 'belongs_to' }]
    units.pop
    result = run_pass(baseline: initial.cache, full: false)
    expect(result.dependencies.fetch(%w[poro RefCaller])).to eq([
                                                                  { 'type' => 'model', 'target' => 'Account',
                                                                    'via' => 'belongs_to' }
                                                                ])
  end

  it 'keeps an identical legacy scanner edge independent of this pass' do
    units.first['dependencies'] = [edge]
    initial = run_pass
    expect(initial.cache['owners'].find { |entry| entry['identifier'] == 'RefCaller' }['added']).to eq([])
    units.pop
    expect(run_pass(baseline: initial.cache, full: false).dependencies.fetch(%w[poro RefCaller])).to eq([edge])
  end

  it 'does not subtract previous additions from freshly re-extracted scanner results' do
    initial = run_pass
    units.first['dependencies'] = [edge]
    units.pop
    expect(run_pass(baseline: initial.cache, refreshed: [%w[poro RefCaller]], full: false)
      .dependencies.fetch(%w[poro RefCaller])).to eq([edge])
  end

  it 'removes stale additions when a formerly unique target becomes type-ambiguous, keeping an ambiguous span' do
    initial = run_pass
    units.first['dependencies'] = [edge]
    units << unit('RefTarget', 'app/models/ref_target.rb', 'model')
    result = run_pass(baseline: initial.cache, refreshed: [%w[model RefTarget]], full: false)
    expect(result.dependencies.fetch(%w[poro RefCaller])).to eq([])
    spans = result.references.fetch(%w[poro RefCaller])
    expect(spans.map { |span| span.values_at('confidence', 'candidates') }.uniq)
      .to eq([['ambiguous', [{ 'target' => 'RefTarget', 'target_type' => 'model' },
                             { 'target' => 'RefTarget', 'target_type' => 'poro' }]]])
    expect(spans).to all(satisfy { |span| !span.key?('target') })
  end

  it 'requires a rebuild rather than resolve current source against stale retained metadata' do
    initial = run_pass
    allow(session).to receive(:consumed_source?).with(:poros, 'app/models/ref_caller.rb').and_return(false)
    expect { run_pass(baseline: initial.cache, full: false) }.to raise_error(
      Woods::SourceReferences::RebuildRequired, /full extraction/i
    )
  end

  it 'does not let a refreshed sibling certify changed source for a retained typed caller' do
    initial = run_pass
    units.first['dependencies'] = [edge]
    sources['app/models/ref_caller.rb'] += "\n# changed since this unit was extracted\n"
    # A sibling unit can acknowledge the same path in the per-extractor ledger.
    allow(session).to receive(:consumed_source?).and_return(true)
    expect { run_pass(baseline: initial.cache, refreshed: [%w[poro RefTarget]], full: false) }
      .to raise_error(Woods::SourceReferences::RebuildRequired, /unverified source/)
  end

  it 'requires a rebuild when a retained caller loses its ownership record' do
    initial = run_pass
    units.first['dependencies'] = [edge]
    initial.cache['owners'].reject! { |owner| owner['identifier'] == 'RefCaller' }
    units.pop
    expect { run_pass(baseline: initial.cache, full: false) }
      .to raise_error(Woods::SourceReferences::RebuildRequired, /ownership/)
  end

  it 'requires matching ownership source paths before removing prior additions' do
    initial = run_pass
    units.first['dependencies'] = [edge]
    initial.cache['owners'].find { |owner| owner['identifier'] == 'RefCaller' }['file_path'] = 'app/models/other.rb'
    expect { run_pass(baseline: initial.cache, full: false) }
      .to raise_error(Woods::SourceReferences::RebuildRequired, /ownership/)
  end

  it 'rejects a lost cache on an incremental run' do
    expect { run_pass(full: false) }.to raise_error(Woods::SourceReferences::RebuildRequired)
  end

  it 'refuses an existing eligible source omitted from the capture' do
    path = 'app/models/ref_caller.rb'
    allow(session).to receive(:source_identity).with(path).and_return(nil)
    allow(File).to receive(:exist?).and_call_original
    allow(File).to receive(:exist?).with(File.join(root, path)).and_return(true)
    expect { run_pass }.to raise_error(Woods::ExtractionError, /capture/)
  end

  it 'fails a syntax error rather than publishing a falsely empty edge set' do
    sources['app/models/ref_caller.rb'] = 'class RefCaller; def'
    expect { run_pass }.to raise_error(Woods::ExtractionError, /parse/)
  end

  context 'with a job unit as the caller' do
    let(:sources) do
      {
        'app/models/import_manager.rb' => <<~RUBY,
          class ImportManager
            def perform(id) = LedgerRate.for(ShipmentPlanner.new(id), WidgetCatalog)
          end
        RUBY
        'app/models/ledger_rate.rb' => 'class LedgerRate; end',
        'app/services/shipment_planner.rb' => 'class ShipmentPlanner; end',
        'lib/widget_catalog.rb' => 'class WidgetCatalog; end'
      }
    end
    let(:units) do
      [unit('ImportManager', 'app/models/import_manager.rb', 'job'),
       unit('LedgerRate', 'app/models/ledger_rate.rb', 'poro'),
       unit('ShipmentPlanner', 'app/services/shipment_planner.rb', 'service'),
       unit('WidgetCatalog', 'lib/widget_catalog.rb', 'lib')]
    end

    before do
      %w[ImportManager LedgerRate ShipmentPlanner WidgetCatalog].each { |name| stub_const(name, Class.new) }
    end

    it 'adds resolved edges to the job unit like any other caller' do
      expect(run_pass.dependencies.fetch(%w[job ImportManager])).to contain_exactly(
        { 'type' => 'lib', 'target' => 'WidgetCatalog', 'via' => 'code_reference' },
        { 'type' => 'poro', 'target' => 'LedgerRate', 'via' => 'code_reference' },
        { 'type' => 'service', 'target' => 'ShipmentPlanner', 'via' => 'code_reference' }
      )
    end
  end

  context 'with component units as callers' do
    let(:sources) do
      {
        'app/views/shipments/summary_view.rb' => <<~RUBY,
          module Shipments
            class SummaryView < ApplicationView
              def view_template
                render Ui::BadgeComponent.new(label: Shipment.count)
                plain ShipmentQuote.for(@shipment).total
              end
            end
          end
        RUBY
        'app/components/ledger_row_component.rb' => <<~RUBY,
          class LedgerRowComponent < ApplicationView
            def before_render = @policy = LedgerPolicy.new(@user)
            def call = Shipments::SummaryView.new
          end
        RUBY
        'app/views/application_view.rb' => 'class ApplicationView; end',
        'app/components/ui/badge_component.rb' => 'module Ui; class BadgeComponent < ApplicationView; end; end',
        'app/models/shipment.rb' => 'class Shipment; end',
        'app/services/shipment_quote.rb' => 'class ShipmentQuote; end',
        'app/policies/ledger_policy.rb' => 'class LedgerPolicy; end'
      }
    end
    let(:units) do
      [unit('Shipments::SummaryView', 'app/views/shipments/summary_view.rb', 'component'),
       unit('LedgerRowComponent', 'app/components/ledger_row_component.rb', 'view_component'),
       unit('ApplicationView', 'app/views/application_view.rb', 'component'),
       unit('Ui::BadgeComponent', 'app/components/ui/badge_component.rb', 'component'),
       unit('Shipment', 'app/models/shipment.rb', 'model'),
       unit('ShipmentQuote', 'app/services/shipment_quote.rb', 'service'),
       unit('LedgerPolicy', 'app/policies/ledger_policy.rb', 'policy')]
    end

    before do
      base = stub_const('ApplicationView', Class.new)
      stub_const('Shipments', Module.new)
      stub_const('Ui', Module.new)
      %w[Shipments::SummaryView Ui::BadgeComponent LedgerRowComponent].each do |name|
        stub_const(name, Class.new(base))
      end
      %w[Shipment ShipmentQuote LedgerPolicy].each { |name| stub_const(name, Class.new) }
    end

    it 'links a component to the model and service it reads, and to no other component' do
      expect(run_pass.dependencies.fetch(%w[component Shipments::SummaryView])).to eq(
        [{ 'type' => 'model', 'target' => 'Shipment', 'via' => 'code_reference' },
         { 'type' => 'service', 'target' => 'ShipmentQuote', 'via' => 'code_reference' }]
      )
    end

    it 'links a view component to the policy it constructs, and to no other component' do
      expect(run_pass.dependencies.fetch(%w[view_component LedgerRowComponent])).to eq(
        [{ 'type' => 'policy', 'target' => 'LedgerPolicy', 'via' => 'code_reference' }]
      )
    end

    it 'keeps the extractor-owned model edge beside the verified one' do
      scanned = { 'type' => 'model', 'target' => 'Shipment', 'via' => 'data_dependency' }
      units.first['dependencies'] = [scanned]
      result = run_pass
      expect(result.dependencies.fetch(%w[component Shipments::SummaryView])).to start_with(scanned)
      owner = result.cache['owners'].find { |entry| entry['identifier'] == 'Shipments::SummaryView' }
      expect(owner['added'].map { |added| added['target'] }).to eq(%w[Shipment ShipmentQuote])
    end

    it 'publishes no edge from a component whose class is not loaded' do
      hide_const('Shipments::SummaryView')
      expect(run_pass.dependencies.fetch(%w[component Shipments::SummaryView])).to eq([])
    end

    it 'publishes component-to-component edges when the policy asks for them' do
      policy = Woods::SourceReferences::CallerPolicy.new(component: :all)
      expect(run_pass(policy: policy).dependencies.fetch(%w[component Shipments::SummaryView])).to include(
        { 'type' => 'component', 'target' => 'Ui::BadgeComponent', 'via' => 'code_reference' }
      )
    end
  end

  context 'with a GraphQL type as the caller' do
    let(:sources) do
      {
        'app/graphql/types/shipment_type.rb' => <<~RUBY,
          module Types
            class ShipmentType < Types::BaseObject
              field :carrier, Types::CarrierType
              def total = LedgerTotals.for(object)
            end
          end
        RUBY
        'app/graphql/types/base_object.rb' => 'module Types; class BaseObject; end; end',
        'app/graphql/types/carrier_type.rb' => 'module Types; class CarrierType < BaseObject; end; end'
      }
    end
    let(:units) do
      [unit('Types::ShipmentType', 'app/graphql/types/shipment_type.rb', 'graphql_type'),
       unit('Types::BaseObject', 'app/graphql/types/base_object.rb', 'graphql_type'),
       unit('Types::CarrierType', 'app/graphql/types/carrier_type.rb', 'graphql_type')]
    end
    let(:caller_key) { %w[graphql_type Types::ShipmentType] }
    let(:extractor_keys) { { graphql_type: :graphql, service: :services } }

    before do
      stub_const('Types', Module.new)
      base = stub_const('Types::BaseObject', Class.new)
      %w[Types::ShipmentType Types::CarrierType].each { |name| stub_const(name, Class.new(base)) }
    end

    it 'adds no edge to another GraphQL unit or to a constant that does not exist' do
      expect(run_pass.dependencies.fetch(caller_key)).to eq([])
    end

    it 'targets a constant created later without the type file changing or being parsed again' do
      initial = run_pass
      sources['app/services/ledger_totals.rb'] = 'class LedgerTotals; end'
      stub_const('LedgerTotals', Class.new)
      units << unit('LedgerTotals', 'app/services/ledger_totals.rb', 'service')
      expect(collector).to receive(:call).with(sources.fetch('app/services/ledger_totals.rb')).once.and_call_original
      expect(collector).not_to receive(:call).with(sources.fetch('app/graphql/types/shipment_type.rb'))
      result = run_pass(baseline: initial.cache, refreshed: [%w[service LedgerTotals]], full: false)
      expect(result.dependencies.fetch(caller_key)).to eq(
        [{ 'type' => 'service', 'target' => 'LedgerTotals', 'via' => 'code_reference' }]
      )
    end

    it 'adds no second (target, via) pair when the extractor already emitted one with a guessed type' do
      sources['app/services/ledger_totals.rb'] = 'class LedgerTotals; end'
      stub_const('LedgerTotals', Class.new)
      units << unit('LedgerTotals', 'app/services/ledger_totals.rb', 'service')
      guessed = { 'type' => 'model', 'target' => 'LedgerTotals', 'via' => 'code_reference' }
      units.first['dependencies'] = [guessed]
      result = run_pass
      expect(result.dependencies.fetch(caller_key)).to eq([guessed])
      expect(result.cache['owners'].find { |owner| owner['identifier'] == 'Types::ShipmentType' }['added']).to eq([])
    end

    it 'withdraws the edge when the constant goes away again' do
      sources['app/services/ledger_totals.rb'] = 'class LedgerTotals; end'
      stub_const('LedgerTotals', Class.new)
      units << unit('LedgerTotals', 'app/services/ledger_totals.rb', 'service')
      initial = run_pass
      units.first['dependencies'] = initial.dependencies.fetch(caller_key)
      units.pop
      hide_const('LedgerTotals')
      expect(run_pass(baseline: initial.cache, full: false).dependencies.fetch(caller_key)).to eq([])
    end
  end

  context 'with the remaining constant-owned types as callers' do
    let(:caller_types) do
      %w[mailer serializer decorator validator policy manager pundit_policy action_cable_channel
         graphql_mutation graphql_resolver graphql_query]
    end
    let(:sources) do
      caller_types.to_h { |type| ["app/callers/ref_#{type}.rb", "class Ref#{camel(type)}; def call = RefTarget; end"] }
                  .merge('app/models/ref_target.rb' => 'class RefTarget; end')
    end
    let(:units) do
      caller_types.map { |type| unit("Ref#{camel(type)}", "app/callers/ref_#{type}.rb", type) } +
        [unit('RefTarget', 'app/models/ref_target.rb', 'model')]
    end

    def camel(type) = type.split('_').map(&:capitalize).join

    before { caller_types.each { |type| stub_const("Ref#{camel(type)}", Class.new) } }

    it 'adds a verified model edge for each of them' do
      result = run_pass
      caller_types.each do |type|
        expect(result.dependencies.fetch([type, "Ref#{camel(type)}"])).to eq([edge.merge('type' => 'model')])
      end
    end
  end

  context 'with plain validator objects as targets' do
    let(:sources) do
      {
        'app/models/widget.rb' => <<~RUBY,
          class Widget
            validate -> { WidgetInStockValidator.new(self).validate }, if: :active?
            validate -> { BatchValidator.new(line_items, validate_with: LineQuantityValidator).validate }
          end
        RUBY
        'app/validators/widget_in_stock_validator.rb' => 'class WidgetInStockValidator; end',
        'app/validators/batch_validator.rb' => 'class BatchValidator; end',
        'app/validators/line_quantity_validator.rb' => 'class LineQuantityValidator; end'
      }
    end
    let(:units) do
      [unit('Widget', 'app/models/widget.rb', 'model'),
       unit('WidgetInStockValidator', 'app/validators/widget_in_stock_validator.rb', 'validator'),
       unit('BatchValidator', 'app/validators/batch_validator.rb', 'validator'),
       unit('LineQuantityValidator', 'app/validators/line_quantity_validator.rb', 'validator')]
    end

    before do
      %w[Widget WidgetInStockValidator BatchValidator LineQuantityValidator].each do |c|
        stub_const(c, Class.new)
      end
    end

    it 'links a model to the validator it constructs and the validator class it passes as an option' do
      edges = run_pass.dependencies.fetch(%w[model Widget])
      expect(edges).to contain_exactly(
        *%w[BatchValidator LineQuantityValidator WidgetInStockValidator].map do |target|
          { 'type' => 'validator', 'target' => target, 'via' => 'code_reference' }
        end
      )
    end
  end

  it 'reports a captured-source read failure with the path and retry guidance' do
    error = Woods::SourceInputs::StableReader::Error.new('source_snapshot_mismatch')
    allow(session).to receive(:read_source).with('app/models/ref_caller.rb').and_raise(error)
    expect { run_pass }.to raise_error(
      Woods::ExtractionError, %r{app/models/ref_caller.rb.*source_snapshot_mismatch.*fresh process}
    )
  end

  it 'excludes external, generated and vendored files from source analysis' do
    units << unit('Outside', '/gems/outside.rb')
    units << unit('Vendor', 'vendor/bundle/vendor.rb')
    units << unit('Asset', 'app/assets/example.rb')
    expect(session).not_to receive(:read_source).with('/gems/outside.rb')
    expect(session).not_to receive(:read_source).with('vendor/bundle/vendor.rb')
    expect(session).not_to receive(:read_source).with('app/assets/example.rb')
    expect(run_pass.cache['files'].keys).to match_array(sources.keys)
  end
end
