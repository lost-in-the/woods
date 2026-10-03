# frozen_string_literal: true

require 'spec_helper'
require 'woods/extractors/view_engines/haml'

RSpec.describe Woods::Extractors::ViewEngines::Haml do
  subject(:engine) { described_class.new }

  it 'is a ViewEngines::Base subclass so it satisfies the template-engine contract' do
    expect(described_class.ancestors).to include(Woods::Extractors::ViewEngines::Base)
  end

  describe '#extensions' do
    it 'returns both .html.haml and .haml' do
      expect(engine.extensions).to contain_exactly('.html.haml', '.haml')
    end
  end

  describe '#name' do
    it 'is :haml' do
      expect(engine.name).to eq(:haml)
    end
  end

  describe '#handles?' do
    it 'matches .html.haml' do
      expect(engine.handles?('app/views/widgets/show.html.haml')).to be true
    end

    it 'matches bare .haml' do
      expect(engine.handles?('app/views/widgets/show.haml')).to be true
    end

    it 'rejects .erb' do
      expect(engine.handles?('app/views/widgets/show.html.erb')).to be false
    end
  end

  describe '#scan_partials' do
    it 'extracts = render "path"' do
      expect(engine.scan_partials("= render 'widgets/header'")).to eq(['widgets/header'])
    end

    it 'extracts - render "path"' do
      expect(engine.scan_partials("- render 'widgets/header'")).to eq(['widgets/header'])
    end

    it 'extracts render with parentheses' do
      expect(engine.scan_partials("= render('widgets/header', widget: @widget)")).to eq(['widgets/header'])
    end

    it 'extracts render partial: with locals' do
      source = "= render partial: 'ledgers/row', locals: { ledger: @ledger }"
      expect(engine.scan_partials(source)).to eq(['ledgers/row'])
    end

    it 'extracts the partial: option when collection: comes first' do
      source = "= render collection: @shipments, partial: 'shipments/shipment', as: :shipment"
      expect(engine.scan_partials(source)).to eq(['shipments/shipment'])
    end

    it 'extracts the partial: option from a call continued over comma-terminated lines' do
      source = <<~HAML
        = render collection: @shipments,
          as: :shipment,
          partial: 'shipments/shipment'
      HAML
      expect(engine.scan_partials(source)).to eq(['shipments/shipment'])
    end

    it 'does not join a partial: option from an unrelated later line' do
      source = <<~HAML
        = render WidgetComponent.new(widget: @widget)
        = widget_options(partial: 'not/a_partial')
      HAML
      expect(engine.scan_partials(source)).to eq([])
    end

    it 'extracts render :partial => "path" and render :symbol' do
      source = <<~HAML
        = render :partial => 'widgets/header'
        = render :footer
      HAML
      expect(engine.scan_partials(source)).to contain_exactly('widgets/header', 'footer')
    end

    it 'does not record a component render as a partial' do
      expect(engine.scan_partials('= render WidgetComponent.new(widget: @widget)')).to eq([])
    end

    it 'reads render calls inside a :ruby filter' do
      source = <<~HAML
        :ruby
          header = render 'widgets/header'
        %div= header
      HAML
      expect(engine.scan_partials(source)).to eq(['widgets/header'])
    end

    it 'ignores render text inside :plain, :javascript, and :css filters' do
      source = <<~HAML
        :plain
          render 'plain/text'
        :javascript
          var x = "render 'js/text'";
        :css
          .render { content: "render 'css/text'"; }
        = render 'widgets/real'
      HAML
      expect(engine.scan_partials(source)).to eq(['widgets/real'])
    end

    it 'ignores render calls inside -# silent comments' do
      source = <<~HAML
        -# = render 'widgets/old'
        -#
          = render 'widgets/older'
        = render 'widgets/current'
      HAML
      expect(engine.scan_partials(source)).to eq(['widgets/current'])
    end

    it 'returns an empty array for empty source' do
      expect(engine.scan_partials('')).to eq([])
    end
  end

  describe '#scan_instance_variables' do
    it 'extracts @ivars in sorted order, deduplicated' do
      source = <<~HAML
        %h1= @widget.name
        %p{ data: { id: @ledger.id } }= @widget.owner
      HAML
      expect(engine.scan_instance_variables(source)).to eq(%w[@ledger @widget])
    end

    it 'returns an empty array for empty source' do
      expect(engine.scan_instance_variables('')).to eq([])
    end
  end

  describe '#scan_helpers' do
    it 'detects common Rails helpers in HAML lines and attribute hashes' do
      source = <<~HAML
        = link_to 'Widgets', widgets_path
        %img{ src: image_tag(@widget.photo) }
        != number_to_currency @widget.price
      HAML
      expect(engine.scan_helpers(source)).to include('link_to', 'image_tag', 'number_to_currency')
    end

    it 'detects the render helper for a component render' do
      expect(engine.scan_helpers('= render WidgetComponent.new(widget: @widget)')).to eq(['render'])
    end

    it 'ignores helper names inside a :javascript filter' do
      source = <<~HAML
        :javascript
          link_to("not a helper");
      HAML
      expect(engine.scan_helpers(source)).to eq([])
    end

    it 'returns an empty array for empty source' do
      expect(engine.scan_helpers('')).to eq([])
    end
  end

  describe '#resolve_partial_identifier' do
    it 'resolves namespaced partial paths to a .html.haml identifier' do
      result = engine.resolve_partial_identifier('ledgers/row', 'widgets/show.html.haml')
      expect(result).to eq('ledgers/_row.html.haml')
    end

    it 'resolves bare partial names relative to the current template directory' do
      result = engine.resolve_partial_identifier('row', 'widgets/show.html.haml')
      expect(result).to eq('widgets/_row.html.haml')
    end
  end

  describe '#scan_navigation_candidates' do
    def helpers_via(source, via)
      engine.scan_navigation_candidates(source).select { |c| c[:via] == via }.map { |c| c[:helper] }
    end

    it 'emits link_to candidates from every _path/_url helper' do
      source = <<~HAML
        = link_to 'Widgets', widgets_path
        %a{ href: ledger_url(@ledger) } Ledger
      HAML
      expect(helpers_via(source, :link_to)).to include('widgets_path', 'ledger_url')
    end

    it 'follows a link_to continued over comma-terminated lines' do
      source = <<~HAML
        = link_to t("widgets.disconnect"),
          widget_connection_path,
          method: :delete
      HAML
      expect(helpers_via(source, :link_to)).to eq(['widget_connection_path'])
    end

    it 'emits a form_action candidate from a single-line form_with' do
      source = '= form_with model: @widget, url: widgets_path do |f|'
      expect(helpers_via(source, :form_action)).to eq(['widgets_path'])
    end

    it 'emits a form_action candidate from a form_with continued over comma-terminated lines' do
      source = <<~HAML
        = form_with model: @shipment,
          url: shipment_tracking_path(@shipment),
          method: :patch do |f|
          = f.submit
      HAML
      expect(helpers_via(source, :form_action)).to eq(['shipment_tracking_path'])
    end

    it 'does not take a route helper from a later line as the form action' do
      source = <<~HAML
        = form_for @widget do |f|
          = f.submit
        = link_to 'Back', widgets_path
      HAML
      expect(helpers_via(source, :form_action)).to eq([])
    end

    it 'ignores route helpers inside a :javascript filter' do
      source = <<~'HAML'
        :javascript
          var url = "#{widgets_path}";
      HAML
      expect(engine.scan_navigation_candidates(source)).to eq([])
    end

    it 'returns an empty array for source with no route helpers' do
      expect(engine.scan_navigation_candidates('%h1 static')).to eq([])
    end
  end
end
