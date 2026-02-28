# frozen_string_literal: true

require 'spec_helper'
require 'set'
require 'codebase_index/extractors/view_component_extractor'

RSpec.describe CodebaseIndex::Extractors::ViewComponentExtractor do
  # ── Test helpers ────────────────────────────────────────────────────────

  let(:rails_root) { Pathname.new('/rails') }
  let(:logger) { double('Logger', error: nil, warn: nil, info: nil) }

  # Hash of path (String) => content (String) for file stubs
  let(:file_system) { {} }

  before do
    stub_const('Rails', double('Rails', root: rails_root, logger: logger))
    stub_const('CodebaseIndex::ModelNameCache', double('ModelNameCache', model_names_regex: /\b(?:User|Post)\b/))

    allow(File).to receive(:exist?) { |path| file_system.key?(path.to_s) }
    allow(File).to receive(:read) { |path| file_system.fetch(path.to_s, '') }
  end

  # Build a mock ViewComponent::Base with descendants support
  def build_view_component_base(descendants: [])
    base = Class.new
    base.define_singleton_method(:name) { 'ViewComponent::Base' }
    base.define_singleton_method(:descendants) { descendants }
    base
  end

  # Build a mock component class
  def build_component(name:, superclass: nil, methods: [:call], params: [])
    klass = Class.new
    klass.define_singleton_method(:name) { name }
    klass.define_singleton_method(:public_instance_methods) { |_inherited = true| methods }
    klass.define_singleton_method(:instance_methods) { |_inherited = true| methods }
    klass.define_singleton_method(:superclass) { superclass || Object }

    init_method = double('Method', parameters: params)
    klass.define_singleton_method(:instance_method) do |method_name|
      method_name == :initialize ? init_method : super(method_name)
    end

    klass
  end

  # ── When ViewComponent is not loaded ────────────────────────────────

  describe '#extract_all' do
    context 'when ViewComponent gem is not loaded' do
      it 'returns an empty array' do
        extractor = described_class.new
        expect(extractor.extract_all).to eq([])
      end
    end

    context 'when ViewComponent gem is loaded' do
      let(:component_class) do
        build_component(
          name: 'CardComponent',
          params: [%i[keyreq title], %i[key subtitle]]
        )
      end

      let(:file_system) do
        {
          '/rails/app/components/card_component.rb' => <<~RUBY
            class CardComponent < ViewComponent::Base
              renders_one :header
              renders_many :items, ItemComponent

              def initialize(title:, subtitle: nil)
                @title = title
                @subtitle = subtitle
              end
            end
          RUBY
        }
      end

      before do
        base = build_view_component_base(descendants: [component_class])
        component_class.define_singleton_method(:superclass) { base }
        stub_const('ViewComponent::Base', base)
      end

      it 'discovers ViewComponent::Base descendants' do
        extractor = described_class.new
        units = extractor.extract_all

        expect(units.size).to eq(1)
        expect(units.first.identifier).to eq('CardComponent')
        expect(units.first.type).to eq(:view_component)
      end

      it 'extracts slots' do
        extractor = described_class.new
        unit = extractor.extract_all.first

        slots = unit.metadata[:slots]
        expect(slots).to include(a_hash_including(name: 'header', type: :one))
        expect(slots).to include(a_hash_including(name: 'items', type: :many, class: 'ItemComponent'))
      end

      it 'extracts initialize params' do
        extractor = described_class.new
        unit = extractor.extract_all.first

        params = unit.metadata[:initialize_params]
        expect(params).to include(a_hash_including(name: :title, type: :keyword_required))
        expect(params).to include(a_hash_including(name: :subtitle, type: :keyword_optional))
      end

      it 'extracts renders_one and renders_many metadata' do
        extractor = described_class.new
        unit = extractor.extract_all.first

        expect(unit.metadata[:renders_one]).to eq(['header'])
        expect(unit.metadata[:renders_many]).to eq(['items'])
      end
    end
  end

  # ── extract_component ─────────────────────────────────────────────────

  describe '#extract_component' do
    before do
      base = build_view_component_base(descendants: [])
      stub_const('ViewComponent::Base', base)
    end

    context 'with an anonymous component (nil name)' do
      it 'returns nil' do
        anon_class = Class.new
        anon_class.define_singleton_method(:name) { nil }

        extractor = described_class.new
        expect(extractor.extract_component(anon_class)).to be_nil
      end
    end

    context 'with a preview class' do
      it 'returns nil for ViewComponent::Preview subclasses' do
        preview_base = Class.new
        stub_const('ViewComponent::Preview', preview_base)

        preview_klass = Class.new(preview_base)
        preview_klass.define_singleton_method(:name) { 'CardComponentPreview' }

        extractor = described_class.new
        expect(extractor.extract_component(preview_klass)).to be_nil
      end
    end

    context 'with a framework-internal component (no file_path, no source)' do
      it 'returns nil' do
        internal_class = build_component(name: 'ViewComponent::InternalThing', params: [])

        extractor = described_class.new
        result = extractor.extract_component(internal_class)
        expect(result).to be_nil
      end
    end

    context 'with a valid component' do
      let(:component_class) do
        build_component(
          name: 'AlertComponent',
          params: [%i[keyreq message]]
        )
      end

      let(:file_system) do
        {
          '/rails/app/components/alert_component.rb' => <<~RUBY
            class AlertComponent < ViewComponent::Base
              def initialize(message:)
                @message = message
              end

              def call
                content_tag :div, @message, class: "alert"
              end
            end
          RUBY
        }
      end

      it 'creates an ExtractedUnit with correct type and identifier' do
        extractor = described_class.new
        unit = extractor.extract_component(component_class)

        expect(unit).to be_a(CodebaseIndex::ExtractedUnit)
        expect(unit.type).to eq(:view_component)
        expect(unit.identifier).to eq('AlertComponent')
      end

      it 'populates source_code' do
        extractor = described_class.new
        unit = extractor.extract_component(component_class)

        expect(unit.source_code).to include('class AlertComponent')
      end
    end

    context 'when extraction raises an error' do
      let(:file_system) do
        { '/rails/app/components/broken_component.rb' => 'class BrokenComponent; end' }
      end

      it 'logs the error and returns nil' do
        klass = Class.new
        klass.define_singleton_method(:name) { 'BrokenComponent' }
        klass.define_singleton_method(:instance_methods) { |_| [] }
        klass.define_singleton_method(:public_instance_methods) { |_| raise StandardError, 'boom' }

        extractor = described_class.new
        result = extractor.extract_component(klass)
        expect(result).to be_nil
        expect(logger).to have_received(:error).with(/BrokenComponent/)
      end
    end
  end

  # ── Sidecar template detection ────────────────────────────────────────

  describe 'sidecar template detection' do
    let(:component_class) do
      build_component(name: 'ButtonComponent', params: [])
    end

    let(:file_system) do
      {
        '/rails/app/components/button_component.rb' => <<~RUBY,
          class ButtonComponent < ViewComponent::Base
            def initialize; end
          end
        RUBY
        '/rails/app/components/button_component.html.erb' => '<button><%= content %></button>'
      }
    end

    before do
      base = build_view_component_base(descendants: [component_class])
      component_class.define_singleton_method(:superclass) { base }
      stub_const('ViewComponent::Base', base)
    end

    it 'detects sidecar .html.erb templates' do
      extractor = described_class.new
      unit = extractor.extract_all.first

      expect(unit.metadata[:sidecar_template]).to eq('/rails/app/components/button_component.html.erb')
    end
  end

  # ── Preview class detection ───────────────────────────────────────────

  describe 'preview class detection' do
    let(:component_class) do
      build_component(name: 'BannerComponent', params: [])
    end

    let(:file_system) do
      { '/rails/app/components/banner_component.rb' => 'class BannerComponent < ViewComponent::Base; end' }
    end

    before do
      base = build_view_component_base(descendants: [component_class])
      component_class.define_singleton_method(:superclass) { base }
      stub_const('ViewComponent::Base', base)

      preview_base = Class.new
      stub_const('ViewComponent::Preview', preview_base)

      preview_klass = Class.new(preview_base)
      preview_klass.define_singleton_method(:name) { 'BannerComponentPreview' }
      stub_const('BannerComponentPreview', preview_klass)
    end

    it 'detects preview classes' do
      extractor = described_class.new
      unit = extractor.extract_all.first

      expect(unit.metadata[:preview_class]).to eq('BannerComponentPreview')
    end
  end

  # ── Collection support detection ──────────────────────────────────────

  describe 'collection support detection' do
    let(:component_class) do
      build_component(name: 'RowComponent', params: [%i[keyreq item]])
    end

    let(:file_system) do
      {
        '/rails/app/components/row_component.rb' => <<~RUBY
          class RowComponent < ViewComponent::Base
            with_collection_parameter :item

            def initialize(item:)
              @item = item
            end
          end
        RUBY
      }
    end

    before do
      base = build_view_component_base(descendants: [component_class])
      component_class.define_singleton_method(:superclass) { base }
      stub_const('ViewComponent::Base', base)
    end

    it 'detects with_collection_parameter' do
      extractor = described_class.new
      unit = extractor.extract_all.first

      expect(unit.metadata[:collection_support]).to be true
    end
  end

  # ── Dependency extraction ─────────────────────────────────────────────

  describe 'dependency extraction' do
    let(:component_class) do
      build_component(name: 'PageComponent', params: [])
    end

    let(:file_system) do
      {
        '/rails/app/components/page_component.rb' => <<~RUBY
          class PageComponent < ViewComponent::Base
            renders_one :header, HeaderComponent
            renders_many :cards, CardComponent
            include ApplicationHelper

            def call
              render(FooterComponent.new)
              @user = User.find(1)
            end
          end
        RUBY
      }
    end

    before do
      base = build_view_component_base(descendants: [component_class])
      component_class.define_singleton_method(:superclass) { base }
      stub_const('ViewComponent::Base', base)
    end

    it 'detects rendered sub-components' do
      extractor = described_class.new
      unit = extractor.extract_all.first

      render_deps = unit.dependencies.select { |d| d[:type] == :component && d[:via] == :render }
      expect(render_deps.map { |d| d[:target] }).to include('FooterComponent')
    end

    it 'detects slot component dependencies' do
      extractor = described_class.new
      unit = extractor.extract_all.first

      slot_deps = unit.dependencies.select { |d| d[:type] == :component && d[:via] == :slot }
      expect(slot_deps.map { |d| d[:target] }).to include('HeaderComponent', 'CardComponent')
    end

    it 'detects model references' do
      extractor = described_class.new
      unit = extractor.extract_all.first

      model_deps = unit.dependencies.select { |d| d[:type] == :model }
      expect(model_deps.map { |d| d[:target] }).to include('User')
    end

    it 'detects helper includes' do
      extractor = described_class.new
      unit = extractor.extract_all.first

      helper_deps = unit.dependencies.select { |d| d[:type] == :helper }
      expect(helper_deps).to include(a_hash_including(target: 'ApplicationHelper', via: :include))
    end

    it 'includes :via key on all dependencies' do
      extractor = described_class.new
      unit = extractor.extract_all.first

      unit.dependencies.each do |dep|
        expect(dep).to have_key(:via), "Dependency #{dep.inspect} missing :via key"
      end
    end
  end

  # ── Callback extraction ───────────────────────────────────────────────

  describe 'callback extraction' do
    let(:component_class) do
      build_component(name: 'TimerComponent', params: [])
    end

    let(:file_system) do
      {
        '/rails/app/components/timer_component.rb' => <<~RUBY
          class TimerComponent < ViewComponent::Base
            before_render :set_time

            def before_render
              @rendered_at = Time.current
            end

            private

            def set_time
              @time = Time.current
            end
          end
        RUBY
      }
    end

    before do
      base = build_view_component_base(descendants: [component_class])
      component_class.define_singleton_method(:superclass) { base }
      stub_const('ViewComponent::Base', base)
    end

    it 'extracts before_render callbacks' do
      extractor = described_class.new
      unit = extractor.extract_all.first

      callbacks = unit.metadata[:callbacks]
      expect(callbacks).to include(a_hash_including(kind: :before_render, method: 'set_time'))
      expect(callbacks).to include(a_hash_including(kind: :before_render, method: :inline))
    end
  end

  # ── Content areas (legacy API) ────────────────────────────────────────

  describe 'content areas extraction' do
    let(:component_class) do
      build_component(name: 'LegacyComponent', params: [])
    end

    let(:file_system) do
      {
        '/rails/app/components/legacy_component.rb' => <<~RUBY
          class LegacyComponent < ViewComponent::Base
            with_content_areas :header, :body, :footer
          end
        RUBY
      }
    end

    before do
      base = build_view_component_base(descendants: [component_class])
      component_class.define_singleton_method(:superclass) { base }
      stub_const('ViewComponent::Base', base)
    end

    it 'extracts content areas' do
      extractor = described_class.new
      unit = extractor.extract_all.first

      expect(unit.metadata[:content_areas]).to match_array(%w[header body footer])
    end
  end
end
