# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'woods'
require 'woods/extracted_unit'
require 'woods/extractors/frontend_references'

RSpec.describe Woods::Extractors::FrontendReferences do
  def scan(source)
    Woods::Extractors::FrontendReferences::Scanner.scan(source)
  end

  describe 'Scanner' do
    it 'reads x-data names from HTML attributes, with and without arguments' do
      source = <<~ERB
        <div x-data="dropdown"></div>
        <div x-data='productSelector({ "sku": "<%= sku %>" })'></div>
        <div x-data="  toggle()  "></div>
        <div x-data="{ open: false }"></div>
        <div x-data></div>
        <div x-data="<%= dynamic %>"></div>
        <div x-data="$store.cart"></div>
        <div x-data="Widgets.picker()"></div>
      ERB

      expect(scan(source)['alpine_data']).to eq(%w[dropdown productSelector toggle])
    end

    it 'records no name for an anonymous Alpine scope' do
      source = <<~TEXT
        <div x-data="true"></div>
        <div x-data='false'></div>
        <div x-data="null"></div>
        <div x-data="this"></div>
        <div x-data="undefined"></div>
        <div x-data></div>
        <div x-data="{ open: false }"></div>
        div("x-data": true, class: "panel")
        div("x-data": "true")
        div(x_data: "new Widget()")
        %div{ "x-data" => "  true  " }
        <div x-data="picker"></div>
      TEXT

      expect(scan(source)['alpine_data']).to eq(%w[picker])
    end

    it 'reads x-data from Ruby hash and keyword forms, but not from an assignment' do
      source = <<~RUBY
        div("x-data": "dropdown")
        div(x_data: "picker({ id: \#{id} })")
        tag.div "x-data" => 'legacy()'
        %div{ :"x-data" => "hamlish" }
        x_data = "notAReference"
        max_data: "alsoNot"
      RUBY

      expect(scan(source)['alpine_data']).to eq(%w[dropdown hamlish legacy picker])
    end

    it 'reads every Stimulus controller in a data-controller attribute' do
      source = <<~ERB
        <div data-controller="clipboard ledgers--line-item"></div>
        <div data-controller='toggle'></div>
        <div data-controller="<%= name %> static"></div>
        <div metadata-controller="nope"></div>
      ERB

      expect(scan(source)['stimulus_controller']).to eq(%w[clipboard ledgers--line-item static toggle])
    end

    it 'reads Stimulus controllers from Ruby keyword and data-hash forms' do
      source = <<~RUBY
        div(data_controller: "clipboard")
        div("data-controller" => "legacy")
        div(data: { turbo: false, controller: "toggle picker" })
        div(data: { "controller" => "quoted" })
        div(data: { :controller => 'rocket' })
        = link_to "Widgets", data: { action: "x", params: { controller: "nested" } }
      RUBY

      expect(scan(source)['stimulus_controller']).to eq(%w[clipboard legacy picker quoted rocket toggle])
    end

    it 'does not read a routing controller option as a Stimulus controller' do
      source = <<~RUBY
        link_to "Widgets", controller: "widgets", action: "index"
        url_for({ controller: "ledgers" })
        data_controller = "local"
      RUBY

      expect(scan(source)['stimulus_controller']).to eq([])
    end

    it 'reads custom element tags from HTML, HAML and Phlex element registration' do
      source = <<~TEXT
        <x-shipment-card sku="1"></x-shipment-card>
        <turbo-frame id="a">
          %x-ledger-row{ id: 1 }
        register_element :x_widget_badge
        register_element(:plain)
        <div class="not-a-tag"><%= a <b-c %></div>
        50%x-not-haml
      TEXT

      expect(scan(source)['custom_element']).to eq(%w[b-c turbo-frame x-ledger-row x-shipment-card x-widget-badge])
    end

    it 'returns sorted, unique names and empty lists for plain source' do
      expect(scan(%(<i x-data="b"></i><i x-data="a"></i><i x-data="b"></i>))['alpine_data']).to eq(%w[a b])
      expect(scan('class Plain; end')).to eq('alpine_data' => [], 'stimulus_controller' => [], 'custom_element' => [])
    end
  end

  describe '#apply_frontend_references' do
    let(:host) do
      Class.new do
        include Woods::Extractors::FrontendReferences

        attr_writer :frontend_registry
      end.new
    end

    let(:unit) do
      Woods::ExtractedUnit.new(type: :view_template, identifier: 'widgets/show.html.erb', file_path: nil).tap do |u|
        u.metadata = { template_engine: 'erb' }
        u.dependencies = [{ type: :controller, target: 'WidgetsController', via: :view_render }]
      end
    end

    before do
      require 'woods/extractors/js_module_registry'
      host.frontend_registry = Woods::Extractors::JsModuleRegistry.build(
        { 'app/javascript/controllers/clipboard_controller.js' => '',
          'app/javascript/alpine.js' => 'Alpine.data("dropdown", () => ({}))',
          'app/javascript/card.tsx' => '@Component({ tag: "x-shipment-card" }) export class Card {}' },
        directories: %w[app/javascript]
      )
    end

    it 'adds an edge per resolved name and records the unresolved ones' do
      host.apply_frontend_references(unit, <<~ERB)
        <div x-data="dropdown" data-controller="clipboard missing"></div>
        <x-shipment-card></x-shipment-card><turbo-frame></turbo-frame>
        <div x-data="unknownData()"></div>
      ERB

      expect(unit.dependencies).to eq(
        [{ type: :controller, target: 'WidgetsController', via: :view_render },
         { type: :js_module, target: 'app/javascript/alpine.js', via: :alpine_data },
         { type: :js_module, target: 'app/javascript/controllers/clipboard_controller.js', via: :stimulus_controller },
         { type: :js_module, target: 'app/javascript/card.tsx', via: :custom_element }]
      )
      expect(unit.metadata[:unresolved_frontend_references]).to eq(
        [{ kind: 'alpine_data', name: 'unknownData' }, { kind: 'stimulus_controller', name: 'missing' },
         { kind: 'custom_element', name: 'turbo-frame' }]
      )
    end

    it 'leaves a unit without frontend references untouched' do
      host.apply_frontend_references(unit, '<p>plain</p>')

      expect(unit.dependencies.size).to eq(1)
      expect(unit.metadata).to eq(template_engine: 'erb')
    end

    it 'scans the sidecar template a component names' do
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, 'app/components'))
        File.write(File.join(root, 'app/components/widget_component.html.erb'),
                   %(<div data-controller="clipboard" x-data="dropdown"></div>))
        stub_const('Rails', double('Rails', root: Pathname.new(root)))
        unit.metadata[:sidecar_template] = 'app/components/widget_component.html.erb'

        host.apply_frontend_references(unit, 'class WidgetComponent < ViewComponent::Base; end')

        expect(unit.dependencies.select { |d| d[:type] == :js_module }.map { |d| d[:via] })
          .to eq(%i[alpine_data stimulus_controller])
      end
    end

    it 'does not duplicate an edge the unit already carries' do
      2.times { host.apply_frontend_references(unit, '<div x-data="dropdown"></div>') }

      expect(unit.dependencies.count { |dep| dep[:via] == :alpine_data }).to eq(1)
    end
  end
end
