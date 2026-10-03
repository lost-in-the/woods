# frozen_string_literal: true

require 'spec_helper'
require 'woods/extractors/view_engines/jbuilder'

RSpec.describe Woods::Extractors::ViewEngines::Jbuilder do
  subject(:engine) { described_class.new }

  it 'is a ViewEngines::Base subclass so it satisfies the template-engine contract' do
    expect(described_class.ancestors).to include(Woods::Extractors::ViewEngines::Base)
  end

  describe '#extensions' do
    it 'returns both .json.jbuilder and .jbuilder' do
      expect(engine.extensions).to contain_exactly('.json.jbuilder', '.jbuilder')
    end
  end

  describe '#name' do
    it 'is :jbuilder' do
      expect(engine.name).to eq(:jbuilder)
    end
  end

  describe '#handles?' do
    it 'matches .json.jbuilder' do
      expect(engine.handles?('app/views/api/widgets/show.json.jbuilder')).to be true
    end

    it 'rejects .html.erb' do
      expect(engine.handles?('app/views/widgets/show.html.erb')).to be false
    end
  end

  describe '#scan_partials' do
    it 'extracts json.partial! with a positional path' do
      source = "json.partial! 'api/widgets/widget', widget: @widget"
      expect(engine.scan_partials(source)).to eq(['api/widgets/widget'])
    end

    it 'extracts json.partial! with partial: and locals:' do
      source = "json.partial! partial: 'api/ledgers/ledger', locals: { ledger: @ledger }"
      expect(engine.scan_partials(source)).to eq(['api/ledgers/ledger'])
    end

    it 'extracts json.partial! inside a json.array! block' do
      source = "json.array!(@widgets) { |w| json.partial! 'api/widgets/widget', widget: w }"
      expect(engine.scan_partials(source)).to eq(['api/widgets/widget'])
    end

    it 'extracts the partial: option of json.array!' do
      source = "json.array! @widgets, partial: 'api/widgets/widget', as: :widget"
      expect(engine.scan_partials(source)).to eq(['api/widgets/widget'])
    end

    it 'extracts the partial: option of a named attribute continued over lines' do
      source = <<~RUBY
        json.shipments @ledger.shipments,
                       partial: 'api/shipments/shipment',
                       as: :shipment
      RUBY
      expect(engine.scan_partials(source)).to eq(['api/shipments/shipment'])
    end

    it 'does not record a helper-built or object partial as a partial name' do
      source = <<~RUBY
        json.partial! versioned_template_path(:widget), widget: @widget
        json.partial! @order.customer
      RUBY
      expect(engine.scan_partials(source)).to eq([])
    end

    it 'returns an empty array for empty source' do
      expect(engine.scan_partials('')).to eq([])
    end
  end

  describe '#scan_unresolved_partials' do
    it 'names the helper that builds the partial path at runtime' do
      source = 'json.partial! versioned_template_path(:widget), widget: w'
      expect(engine.scan_unresolved_partials(source)).to eq([{ kind: 'helper', name: 'versioned_template_path' }])
    end

    it 'names the helper passed as the partial: option' do
      source = 'json.partial! partial: versioned_template_path(:ledger), locals: { ledger: @ledger }'
      expect(engine.scan_unresolved_partials(source)).to eq([{ kind: 'helper', name: 'versioned_template_path' }])
    end

    it 'records the object form with its expression' do
      expect(engine.scan_unresolved_partials('json.partial! @order.customer'))
        .to eq([{ kind: 'object', name: '@order.customer' }])
    end

    it 'records nothing for a literal partial path' do
      source = "json.partial! partial: 'api/widgets/widget', locals: { widget: @widget }"
      expect(engine.scan_unresolved_partials(source)).to eq([])
    end

    it 'deduplicates repeated references' do
      source = <<~RUBY
        json.partial! versioned_template_path(:widget), widget: a
        json.partial! versioned_template_path(:widget), widget: b
      RUBY
      expect(engine.scan_unresolved_partials(source)).to eq([{ kind: 'helper', name: 'versioned_template_path' }])
    end
  end

  describe '#scan_instance_variables' do
    it 'extracts @ivars in sorted order' do
      source = "json.id @widget.id\njson.ledger @ledger.name\n"
      expect(engine.scan_instance_variables(source)).to eq(%w[@ledger @widget])
    end
  end

  describe '#resolve_partial_identifier' do
    it 'resolves namespaced partial paths to a .json.jbuilder identifier' do
      result = engine.resolve_partial_identifier('api/widgets/widget', 'api/widgets/index.json.jbuilder')
      expect(result).to eq('api/widgets/_widget.json.jbuilder')
    end

    it 'resolves bare partial names relative to the current template directory' do
      result = engine.resolve_partial_identifier('widget', 'api/widgets/index.json.jbuilder')
      expect(result).to eq('api/widgets/_widget.json.jbuilder')
    end
  end

  describe '#scan_navigation_candidates' do
    it 'emits link_to candidates from _path/_url helpers' do
      source = 'json.url api_widget_url(widget, format: :json)'
      expect(engine.scan_navigation_candidates(source)).to eq([{ helper: 'api_widget_url', via: :link_to }])
    end
  end
end
