# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'woods'
require 'woods/extractors/helper_catalog'

RSpec.describe Woods::Extractors::HelperCatalog do
  include_context 'extractor setup'

  subject(:catalog) { described_class.new(root: rails_root, contexts: contexts, default_context: default_context) }

  let(:contexts) { [] }
  let(:default_context) { nil }

  # A stand-in for a controller or mailer class: a named class with the
  # `_helpers` module Rails builds per class.
  def context_class(name, parent: Object, helpers: Module.new)
    Class.new(parent) do
      define_singleton_method(:name) { name }
      define_singleton_method(:_helpers) { helpers }
    end
  end

  def load_constant(relative_path, source)
    path = create_file(relative_path, source)
    load path
    path
  end

  after do
    %i[CatalogWidgetsHelper CatalogLedgerHelper CatalogFormatting CatalogSession].each do |name|
      Object.send(:remove_const, name) if Object.const_defined?(name, false)
    end
  end

  describe 'source modules under app/helpers' do
    before do
      create_file('app/helpers/date_helper.rb', <<~RUBY)
        module DateHelper
          def pretty_date(value) = value.to_s

          def short_date(value)
            value.to_s
          end

          def self.zone = 'UTC'

          private

          def pad(value) = value
        end
      RUBY
      create_file('app/helpers/admin/widgets_helper.rb', <<~RUBY)
        module Admin
          module WidgetsHelper
            def widget_badge(widget) = widget.to_s
            private def badge_class = 'badge'
            def hidden_badge = nil
            private :hidden_badge
            protected
            def guarded = nil
            public
            def widget_title = 'x'
            class Presenter
              def render = nil
            end
          end
        end
      RUBY
    end

    it 'catalogs the public instance methods each module defines' do
      expect(catalog.names).to eq(Set.new(%w[pretty_date short_date widget_badge widget_title]))
    end

    it 'maps a method name to its module, file and line' do
      expect(catalog.definitions('short_date'))
        .to eq([{ module: 'DateHelper', file: 'app/helpers/date_helper.rb', line: 4 }])
      expect(catalog.definitions('widget_badge'))
        .to eq([{ module: 'Admin::WidgetsHelper', file: 'app/helpers/admin/widgets_helper.rb', line: 3 }])
    end

    it 'lists every module that defines a name, sorted' do
      create_file('app/helpers/ledger_helper.rb', "module LedgerHelper\n  def pretty_date(v) = v\nend\n")

      expect(catalog.candidates('pretty_date')).to eq(%w[DateHelper LedgerHelper])
    end

    it 'merges a module reopened in a second file' do
      create_file('app/helpers/date_extras.rb', "module DateHelper\n  def long_date(v) = v\nend\n")

      expect(catalog.candidates('long_date')).to eq(%w[DateHelper])
      expect(catalog.candidates('pretty_date')).to eq(%w[DateHelper])
    end

    it 'skips a file that does not parse and keeps the rest' do
      create_file('app/helpers/broken_helper.rb', "module BrokenHelper\n  def oops(\n")

      expect(catalog.names).to include('pretty_date')
      expect(catalog.names).not_to include('oops')
    end

    it 'is empty when the app has no helpers directory' do
      expect(described_class.new(root: Pathname.new(Dir.mktmpdir), contexts: []).names).to be_empty
    end

    it 'types a helper module edge by where its file lives' do
      expect(catalog.target_type('DateHelper')).to eq(:poro)
    end
  end

  describe 'runtime cross-check' do
    it 'adds a method the loaded module defines dynamically in its own file' do
      load_constant('app/helpers/catalog_widgets_helper.rb', <<~RUBY)
        module CatalogWidgetsHelper
          def widget_badge(widget) = widget.to_s
          %w[small large].each { |size| define_method("\#{size}_badge") { size } }
          alias_method :widget_tag, :widget_badge
        end
      RUBY

      expect(catalog.names).to eq(Set.new(%w[widget_badge small_badge large_badge widget_tag]))
    end

    it 'keeps a source method the loaded module no longer has' do
      load_constant('app/helpers/catalog_widgets_helper.rb', "module CatalogWidgetsHelper\nend\n")
      create_file('app/helpers/catalog_widgets_helper.rb', "module CatalogWidgetsHelper\n  def fresh = 1\nend\n")

      expect(catalog.names).to eq(Set.new(%w[fresh]))
    end
  end

  describe 'modules a controller mixes in with `helper`' do
    let(:contexts) { [context_class('WidgetsController', helpers: helpers_module)] }
    let(:helpers_module) { Module.new }

    before do
      load_constant('app/lib/catalog_formatting.rb', <<~RUBY)
        module CatalogFormatting
          def money(amount) = amount.to_s
        end
      RUBY
      helpers_module.include(CatalogFormatting)
    end

    it 'catalogs an app module found in a helpers ancestry' do
      expect(catalog.definitions('money'))
        .to eq([{ module: 'CatalogFormatting', file: 'app/lib/catalog_formatting.rb', line: 2 }])
    end

    it 'ignores a helpers ancestor defined outside the application' do
      helpers_module.include(Comparable)

      expect(catalog.modules.keys).to eq(%w[CatalogFormatting])
    end
  end

  describe 'helper_method declarations' do
    let(:application_helpers) { Module.new { def current_session = nil } }
    let(:application) { context_class('ApplicationController', helpers: application_helpers) }
    let(:widgets_helpers) do
      inherited = application_helpers
      Module.new do
        include inherited

        def current_widget = nil
      end
    end
    let(:widgets) { context_class('WidgetsController', parent: application, helpers: widgets_helpers) }
    let(:ledgers) { context_class('LedgersController', parent: application, helpers: application_helpers) }
    let(:contexts) { [widgets, ledgers, application] }
    let(:default_context) { application }

    it 'adds the declared names to the catalog' do
      expect(catalog.names).to eq(Set.new(%w[current_session current_widget]))
    end

    it 'attributes each name to the class that declares it' do
      expect(catalog.declared_helper_methods(application)).to eq(%w[current_session])
      expect(catalog.declared_helper_methods(widgets)).to eq(%w[current_widget])
      expect(catalog.declared_helper_methods(ledgers)).to eq([])
    end

    it 'resolves a declared name through the calling context' do
      expect(catalog.resolve('current_widget', widgets))
        .to eq([{ type: :controller, target: 'WidgetsController', via: :helper_method }])
      expect(catalog.resolve('current_session', widgets))
        .to eq([{ type: :controller, target: 'ApplicationController', via: :helper_method }])
    end

    it 'does not resolve a name the context cannot reach' do
      expect(catalog.resolve('current_widget', ledgers)).to eq([])
    end

    it 'resolves through the default context when there is none' do
      expect(catalog.resolve('current_session', nil))
        .to eq([{ type: :controller, target: 'ApplicationController', via: :helper_method }])
      expect(catalog.resolve('current_widget', nil)).to eq([])
    end
  end

  describe '#resolve for module methods' do
    before do
      create_file('app/helpers/catalog_widgets_helper.rb', "module CatalogWidgetsHelper\n  def label_for(w) = w\nend\n")
      create_file('app/helpers/catalog_ledger_helper.rb', "module CatalogLedgerHelper\n  def label_for(l) = l\nend\n")
      create_file('app/helpers/date_helper.rb', "module DateHelper\n  def pretty_date(v) = v\nend\n")
    end

    it 'returns the one module that defines the name' do
      expect(catalog.resolve('pretty_date', nil)).to eq([{ type: :poro, target: 'DateHelper', via: :helper_call }])
    end

    it 'returns every candidate, marked ambiguous, when nothing at runtime decides' do
      expect(catalog.resolve('label_for', nil)).to eq(
        [{ type: :poro, target: 'CatalogLedgerHelper', via: :helper_call, ambiguous: true },
         { type: :poro, target: 'CatalogWidgetsHelper', via: :helper_call, ambiguous: true }]
      )
    end

    it 'returns the module the context resolves to at runtime' do
      load File.join(tmp_dir, 'app/helpers/catalog_widgets_helper.rb')
      load File.join(tmp_dir, 'app/helpers/catalog_ledger_helper.rb')
      helpers = Module.new do
        include CatalogWidgetsHelper
        include CatalogLedgerHelper
      end

      expect(catalog.resolve('label_for', context_class('WidgetsController', helpers: helpers)))
        .to eq([{ type: :poro, target: 'CatalogLedgerHelper', via: :helper_call }])
    end

    it 'returns nothing for a name outside the catalog' do
      expect(catalog.resolve('link_to', nil)).to eq([])
    end
  end

  describe '#included_names' do
    it 'lists the methods of catalog modules a class includes' do
      load_constant('app/helpers/catalog_widgets_helper.rb',
                    "module CatalogWidgetsHelper\n  def label_for(w) = w\nend\n")
      create_file('app/helpers/date_helper.rb', "module DateHelper\n  def pretty_date(v) = v\nend\n")
      component = Class.new { include CatalogWidgetsHelper }

      expect(catalog.included_names(component)).to eq(Set.new(%w[label_for]))
      expect(catalog.resolve_included('label_for', component))
        .to eq([{ type: :poro, target: 'CatalogWidgetsHelper', via: :helper_call }])
    end

    it 'does not resolve a name the class defines itself' do
      load_constant('app/helpers/catalog_widgets_helper.rb',
                    "module CatalogWidgetsHelper\n  def label_for(w) = w\nend\n")
      component = Class.new do
        include CatalogWidgetsHelper

        def label_for(_widget) = 'own'
      end

      expect(catalog.resolve_included('label_for', component)).to eq([])
    end
  end

  describe 'incremental triggers' do
    let(:application) do
      load_constant('app/controllers/concerns/catalog_session.rb', "module CatalogSession\nend\n")
      context_class('ApplicationController').tap { |klass| klass.include(CatalogSession) }
    end
    let(:helpers_module) { Module.new }
    let(:contexts) { [application, context_class('WidgetsController', parent: application, helpers: helpers_module)] }
    let(:default_context) { application }

    before do
      load_constant('app/lib/catalog_formatting.rb', "module CatalogFormatting\n  def money(a) = a\nend\n")
      helpers_module.include(CatalogFormatting)
    end

    it 're-runs every consumer when a helper file changes' do
      expect(catalog.consumer_keys_for(%w[app/helpers/date_helper.rb]))
        .to eq(%i[view_templates components view_components controllers mailers])
    end

    it 're-runs every consumer when a module mixed in with `helper` changes' do
      expect(catalog.consumer_keys_for(%w[app/lib/catalog_formatting.rb])).to eq(described_class::CONSUMERS)
    end

    it 're-runs the view-side consumers when the default context ancestry changes' do
      expect(catalog.consumer_keys_for(%w[app/controllers/concerns/catalog_session.rb]))
        .to eq(%i[view_templates components view_components])
    end

    it 're-runs nothing for an unrelated or non-Ruby path' do
      expect(catalog.consumer_keys_for(%w[app/models/widget.rb app/helpers/notes.md app/views/a.html.erb])).to eq([])
    end
  end
end
