# frozen_string_literal: true

require 'spec_helper'
require 'set'
require 'tmpdir'
require 'fileutils'
require 'woods'
require 'woods/extracted_unit'
require 'woods/extractors/helper_call_scan'
require 'woods/extractors/helper_catalog'

RSpec.describe Woods::Extractors::HelperCallScan do
  describe '.method_calls' do
    let(:names) { Set.new(%w[pretty_date widget_badge title staff?]) }

    def calls(code, locals: [])
      described_class.method_calls(code, names, locals: locals)
    end

    it 'reports a receiverless call to a catalog name' do
      expect(calls('pretty_date(widget.shipped_at)')).to eq(bare: %w[pretty_date], explicit: [])
    end

    it 'reports each name once, sorted' do
      expect(calls("widget_badge(w)\npretty_date(a)\npretty_date(b)")[:bare]).to eq(%w[pretty_date widget_badge])
    end

    it 'ignores names outside the catalog' do
      expect(calls('link_to t(".label"), render("row")')).to eq(bare: [], explicit: [])
    end

    it 'reports a predicate name with its question mark' do
      expect(calls('if staff? then 1 end')[:bare]).to eq(%w[staff?])
    end

    it 'reports a call through the helpers proxy as explicit' do
      expect(calls('helpers.pretty_date(x)')).to eq(bare: [], explicit: %w[pretty_date])
    end

    it 'reports a helpers call chained on the next line' do
      expect(calls("helpers\n  .pretty_date(x)")[:explicit]).to eq(%w[pretty_date])
    end

    it 'ignores a method called on another receiver' do
      expect(calls('widget.title; widget&.pretty_date; Widget::title')).to eq(bare: [], explicit: [])
    end

    it 'does not treat a range as a receiver' do
      expect(calls('1..title')[:bare]).to eq(%w[title])
    end

    it 'ignores symbols, labels, and instance variables' do
      expect(calls('render :title, title: 1, as: :pretty_date, value: @title')).to eq(bare: [], explicit: [])
    end

    it 'reports a keyword argument value and both ternary branches' do
      expect(calls('tag(label: pretty_date, text: ok ? title : widget_badge)')[:bare])
        .to eq(%w[pretty_date title widget_badge])
    end

    it 'ignores string contents but reads interpolations' do
      expect(calls(%q(a = 'title' + "pretty_date #{widget_badge(w)} title"))[:bare]).to eq(%w[widget_badge])
    end

    it 'returns to string text after a nested interpolation closes' do
      expect(calls(<<~'RUBY')[:bare]).to eq(%w[title])
        "#{tag { "#{title}" }} pretty_date"
      RUBY
    end

    it 'ignores comments and word arrays' do
      expect(calls("# pretty_date\n%w[title pretty_date] + %i(title)")).to eq(bare: [], explicit: [])
    end

    it 'ignores a method definition' do
      expect(calls("def title\n  'x'\nend\ndef self.pretty_date; end")).to eq(bare: [], explicit: [])
    end

    it 'treats an assigned name as a local for the whole source' do
      expect(calls("title\ntitle = 'x'\ntitle ||= 'y'\nwidget_badge")[:bare]).to eq(%w[widget_badge])
    end

    it 'keeps a compared name as a call' do
      expect(calls("title == 'x' || pretty_date =~ /x/")[:bare]).to eq(%w[pretty_date title])
    end

    it 'treats block parameters as locals' do
      expect(calls("widgets.each do |title, i|\n title\nend\nrows.map { |pretty_date| pretty_date }")[:bare]).to eq([])
    end

    it 'treats local_assigns and defined? probes as locals' do
      expect(calls("local_assigns[:title]\nlocal_assigns.fetch(:pretty_date, 1)\ndefined?(widget_badge)\n" \
                   'title + pretty_date + widget_badge')[:bare]).to eq([])
    end

    it 'excludes locals the caller already knows' do
      expect(calls('title + pretty_date', locals: %w[title])[:bare]).to eq(%w[pretty_date])
    end

    it 'stops at an unterminated quote instead of reading its text as code' do
      expect(calls("x = 'open\npretty_date")[:bare]).to eq([])
    end

    it 'skips a heredoc body, apostrophes and all' do
      code = "sql = <<~SQL\n  select title from widgets where it's pretty_date\nSQL\nwidget_badge(w)"
      expect(calls(code)[:bare]).to eq(%w[widget_badge])
    end

    it 'reads the rest of the line that opens a heredoc' do
      expect(calls("tag(<<~TEXT, pretty_date) # note\n  title\nTEXT\n")[:bare]).to eq(%w[pretty_date])
    end

    it 'skips each body when one line opens two heredocs' do
      expect(calls("pair(<<-A, <<-'B')\n  title\n  A\n  pretty_date\n  B\nwidget_badge")[:bare])
        .to eq(%w[widget_badge])
    end

    it 'does not read a shift operator as a heredoc' do
      expect(calls("list << title\nwidget_badge")[:bare]).to eq(%w[title widget_badge])
    end

    it 'scans source that is not valid UTF-8' do
      expect(calls("pretty_date \xFF title".dup.force_encoding(Encoding::UTF_8))[:bare]).to eq(%w[pretty_date title])
    end
  end

  describe 'edges and metadata' do
    include_context 'extractor setup'

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
    let(:catalog) do
      Woods::Extractors::HelperCatalog.new(root: rails_root, contexts: [application, widgets],
                                           default_context: application)
    end

    def context_class(name, parent: Object, helpers: Module.new)
      Class.new(parent) do
        define_singleton_method(:name) { name }
        define_singleton_method(:_helpers) { helpers }
      end
    end

    def unit_for(source, type: :view_template, identifier: 'widgets/show.html.erb')
      Woods::ExtractedUnit.new(type: type, identifier: identifier, file_path: '/x').tap do |unit|
        unit.source_code = source
        unit.metadata = { loc: 1 }
        unit.dependencies = [{ type: :controller, target: 'WidgetsController', via: :view_render }]
      end
    end

    before do
      create_file('app/helpers/date_helper.rb',
                  "module DateHelper\n  def pretty_date(v) = v\n  def short_date(v) = v\nend\n")
      create_file('app/helpers/widgets_helper.rb', "module WidgetsHelper\n  def label_for(w) = w\nend\n")
      create_file('app/helpers/ledgers_helper.rb', "module LedgersHelper\n  def label_for(l) = l\nend\n")
    end

    after do
      %i[ScanBadgeHelper].each { |name| Object.send(:remove_const, name) if Object.const_defined?(name, false) }
    end

    describe '.resolve' do
      it 'groups called names under the module that defines them' do
        calls = { bare: %w[pretty_date short_date], explicit: [] }

        expect(described_class.resolve(catalog, calls, context: widgets)).to eq(
          dependencies: [{ type: :poro, target: 'DateHelper', via: :helper_call }],
          metadata: { helper_calls: { 'DateHelper' => %w[pretty_date short_date] } }
        )
      end

      it 'links a helper_method name to the controller that declares it' do
        calls = { bare: %w[current_session current_widget], explicit: [] }

        expect(described_class.resolve(catalog, calls, context: widgets)).to eq(
          dependencies: [{ type: :controller, target: 'ApplicationController', via: :helper_method },
                         { type: :controller, target: 'WidgetsController', via: :helper_method }],
          metadata: { helper_method_calls: { 'ApplicationController' => %w[current_session],
                                             'WidgetsController' => %w[current_widget] } }
        )
      end

      it 'links an ambiguous name to every candidate and records the ambiguity' do
        result = described_class.resolve(catalog, { bare: %w[label_for], explicit: [] }, context: widgets)

        expect(result[:dependencies]).to eq([{ type: :poro, target: 'LedgersHelper', via: :helper_call },
                                             { type: :poro, target: 'WidgetsHelper', via: :helper_call }])
        expect(result[:metadata]).to eq(
          helper_calls: { 'LedgersHelper' => %w[label_for], 'WidgetsHelper' => %w[label_for] },
          ambiguous_helper_calls: { 'label_for' => %w[LedgersHelper WidgetsHelper] }
        )
      end

      it 'returns nothing to add when no call resolves' do
        expect(described_class.resolve(catalog, { bare: [], explicit: [] }, context: widgets))
          .to eq(dependencies: [], metadata: {})
      end

      it 'resolves only included helper modules for a receiverless call in a class' do
        load create_file('app/helpers/scan_badge_helper.rb', "module ScanBadgeHelper\n  def badge(w) = w\nend\n")
        component = Class.new { include ScanBadgeHelper }
        calls = { bare: %w[badge pretty_date], explicit: %w[short_date] }

        expect(described_class.resolve(catalog, calls, includer: component)).to eq(
          dependencies: [{ type: :poro, target: 'DateHelper', via: :helper_call },
                         { type: :poro, target: 'ScanBadgeHelper', via: :helper_call }],
          metadata: { helper_calls: { 'DateHelper' => %w[short_date], 'ScanBadgeHelper' => %w[badge] } }
        )
      end
    end

    describe '.apply' do
      it 'appends the edges and merges the metadata into the unit' do
        unit = unit_for('<%= pretty_date(x) %>')
        resolution = described_class.resolve(catalog, { bare: %w[pretty_date], explicit: [] }, context: widgets)
        described_class.apply(unit, resolution)

        expect(unit.dependencies).to eq([{ type: :controller, target: 'WidgetsController', via: :view_render },
                                         { type: :poro, target: 'DateHelper', via: :helper_call }])
        expect(unit.metadata).to eq(loc: 1, helper_calls: { 'DateHelper' => %w[pretty_date] })
      end

      it 'leaves a unit with no helper calls exactly as it was' do
        unit = unit_for('<p>static</p>')
        described_class.apply(unit, dependencies: [], metadata: {})

        expect(unit.metadata).to eq(loc: 1)
        expect(unit.dependencies.size).to eq(1)
      end
    end

    describe '.annotate' do
      let(:extractor) { Object.new.tap { |object| object.instance_variable_set(:@helper_catalog, catalog) } }

      it 'links helpers-proxy calls in a controller and lists the helper methods it declares' do
        unit = unit_for("class WidgetsController\n  def show = helpers.pretty_date(1)\n  def title = short_date\nend",
                        type: :controller, identifier: 'WidgetsController')
        described_class.annotate(extractor, unit, widgets)

        expect(unit.dependencies).to include({ type: :poro, target: 'DateHelper', via: :helper_call })
        expect(unit.metadata).to eq(loc: 1, helper_calls: { 'DateHelper' => %w[pretty_date] },
                                    helper_methods: %w[current_widget])
      end

      it 'reads use_helpers and helpers delegation in a component as proxy calls' do
        source = "class BadgeComponent\n  use_helpers :pretty_date\n  delegate :short_date, :other, to: :helpers\nend"
        unit = unit_for(source, type: :view_component, identifier: 'BadgeComponent')
        described_class.annotate(extractor, unit, Class.new)

        expect(unit.metadata[:helper_calls]).to eq('DateHelper' => %w[pretty_date short_date])
        expect(unit.metadata).not_to have_key(:helper_methods)
      end

      it 'reads the sidecar template of a view component' do
        create_file('app/components/badge_component.html.erb',
                    '<p><%= helpers.pretty_date(@at) %> pretty short_date</p>')
        unit = unit_for('class BadgeComponent; end', type: :view_component, identifier: 'BadgeComponent')
        unit.metadata[:sidecar_template] = 'app/components/badge_component.html.erb'
        described_class.annotate(extractor, unit, Class.new)

        expect(unit.metadata[:helper_calls]).to eq('DateHelper' => %w[pretty_date])
      end

      it 'builds one catalog per extractor' do
        fresh = Object.new
        allow(Woods::Extractors::HelperCatalog).to receive(:new).and_return(catalog)
        2.times { described_class.annotate(fresh, unit_for('x', type: :controller), widgets) }

        expect(Woods::Extractors::HelperCatalog).to have_received(:new).once
      end
    end
  end
end
