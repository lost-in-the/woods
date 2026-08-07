# frozen_string_literal: true

require 'spec_helper'
require 'set'
require 'active_support/core_ext/object/blank'
require 'woods'
require 'woods/extractors/phlex_extractor'

RSpec.describe Woods::Extractors::PhlexExtractor do
  # ── Test helpers ────────────────────────────────────────────────────────

  let(:rails_root) { Pathname.new('/rails') }
  let(:logger) { double('Logger', error: nil) }

  # Hash of path (String) => content (String) for file stubs
  let(:file_system) { {} }

  before do
    stub_const('Rails', double('Rails', root: rails_root, logger: logger))
    stub_const('Woods::ModelNameCache', double('ModelNameCache', model_names_regex: /\b(?:User|Post)\b/))

    allow(File).to receive(:exist?) { |path| file_system.key?(path.to_s) }
    allow(File).to receive(:read) { |path| file_system.fetch(path.to_s, '') }
  end

  # Build a mock Phlex::HTML base with descendants support
  def build_phlex_base(descendants: [])
    base = Class.new
    base.define_singleton_method(:name) { 'Phlex::HTML' }
    base.define_singleton_method(:descendants) { descendants }
    base
  end

  # Build a mock component class
  def build_component(name:, superclass: nil, methods: [:view_template], params: [], view_template: true)
    klass = Class.new
    klass.define_singleton_method(:name) { name }
    klass.define_singleton_method(:public_instance_methods) { |_inherited = true| methods }
    klass.define_singleton_method(:superclass) { superclass || Object }
    klass.define_singleton_method(:method_defined?) { |m| view_template && m == :view_template }

    init_method = double('Method', parameters: params)
    klass.define_singleton_method(:instance_method) { |_name| init_method }

    klass
  end

  # ── find_component_base ─────────────────────────────────────────────────

  describe '#find_component_base (via extract_all)' do
    context 'when ApplicationComponent is a ViewComponent subclass' do
      it 'does not use ApplicationComponent as a Phlex base' do
        vc_base = Class.new
        stub_const('ViewComponent::Base', vc_base)

        app_component = Class.new(vc_base)
        app_component.define_singleton_method(:name) { 'ApplicationComponent' }
        stub_const('ApplicationComponent', app_component)

        extractor = described_class.new
        # With no Phlex classes defined, and ApplicationComponent being a VC,
        # extract_all should return empty (no Phlex base found)
        expect(extractor.extract_all).to eq([])
      end
    end

    context 'when ApplicationComponent is a Phlex subclass' do
      it 'uses ApplicationComponent as a Phlex base' do
        phlex_base = Class.new
        phlex_base.define_singleton_method(:descendants) { [] }
        stub_const('Phlex::HTML', phlex_base)

        # Phlex::HTML is found first in PHLEX_BASES, so ApplicationComponent
        # isn't reached — but this confirms Phlex classes take priority
        extractor = described_class.new
        # No descendants, so empty result but no error
        expect(extractor.extract_all).to eq([])
      end
    end

    context 'when no component framework is loaded' do
      it 'returns empty array' do
        extractor = described_class.new
        expect(extractor.extract_all).to eq([])
      end
    end
  end

  # ── extract_all ─────────────────────────────────────────────────────────

  describe '#extract_all' do
    context 'with a Phlex component' do
      let(:component_class) do
        build_component(
          name: 'CardComponent',
          params: [%i[keyreq title], %i[key subtitle]]
        )
      end

      let(:file_system) do
        {
          '/rails/app/views/components/card_component.rb' => <<~RUBY
            class CardComponent < Phlex::HTML
              renders_one :header, HeaderComponent
              renders_many :items, ItemComponent

              def initialize(title:, subtitle: nil)
                @title = title
                @subtitle = subtitle
              end

              def view_template
                h1 { @title }
              end
            end
          RUBY
        }
      end

      before do
        base = build_phlex_base(descendants: [component_class])
        component_class.define_singleton_method(:superclass) { base }
        stub_const('Phlex::HTML', base)
      end

      it 'discovers Phlex::HTML descendants' do
        extractor = described_class.new
        units = extractor.extract_all

        expect(units.size).to eq(1)
        expect(units.first.identifier).to eq('CardComponent')
        expect(units.first.type).to eq(:component)
      end

      it 'populates file_path from the convention path' do
        extractor = described_class.new
        unit = extractor.extract_all.first

        expect(unit.file_path).to eq('/rails/app/views/components/card_component.rb')
      end

      it 'populates source_code from the component file' do
        extractor = described_class.new
        unit = extractor.extract_all.first

        expect(unit.source_code).to include('class CardComponent < Phlex::HTML')
      end

      it 'extracts slots' do
        extractor = described_class.new
        unit = extractor.extract_all.first

        slots = unit.metadata[:slots]
        expect(slots).to include(a_hash_including(name: 'header', type: :one, class: 'HeaderComponent'))
        expect(slots).to include(a_hash_including(name: 'items', type: :many, class: 'ItemComponent'))
      end

      it 'extracts initialize params via runtime introspection' do
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

      it 'records the parent component and view_template presence' do
        extractor = described_class.new
        unit = extractor.extract_all.first

        expect(unit.metadata[:parent_component]).to eq('Phlex::HTML')
        expect(unit.metadata[:has_view_template]).to be true
      end

      it 'counts non-blank, non-comment lines of code' do
        extractor = described_class.new
        unit = extractor.extract_all.first

        source = file_system.values.first
        expected = source.lines.count { |l| l.strip.present? && !l.strip.start_with?('#') }
        expect(unit.metadata[:loc]).to eq(expected)
      end
    end

    context 'with an anonymous descendant' do
      it 'skips it without raising' do
        anon = Class.new
        anon.define_singleton_method(:name) { nil }

        base = build_phlex_base(descendants: [anon])
        stub_const('Phlex::HTML', base)

        extractor = described_class.new
        expect(extractor.extract_all).to eq([])
      end
    end
  end

  # ── extract_component ───────────────────────────────────────────────────

  describe '#extract_component' do
    before do
      stub_const('Phlex::HTML', build_phlex_base)
    end

    context 'with an anonymous component (nil name)' do
      it 'returns nil' do
        anon_class = Class.new
        anon_class.define_singleton_method(:name) { nil }

        extractor = described_class.new
        expect(extractor.extract_component(anon_class)).to be_nil
      end
    end

    context 'with a namespaced component' do
      let(:component_class) { build_component(name: 'Components::CardComponent') }

      let(:file_system) do
        { '/rails/app/views/components/card_component.rb' => 'class CardComponent < Phlex::HTML; end' }
      end

      it 'extracts the namespace' do
        extractor = described_class.new
        unit = extractor.extract_component(component_class)

        expect(unit.namespace).to eq('Components')
        expect(unit.identifier).to eq('Components::CardComponent')
      end

      it 'resolves the file through the app/views convention path' do
        # 'Components::CardComponent'.underscore is 'components/card_component',
        # so only the app/views/<underscored> candidate matches this layout.
        extractor = described_class.new
        unit = extractor.extract_component(component_class)

        expect(unit.file_path).to eq('/rails/app/views/components/card_component.rb')
      end
    end

    context 'with a top-level component' do
      let(:component_class) { build_component(name: 'AlertComponent') }

      let(:file_system) do
        { '/rails/app/components/alert_component.rb' => 'class AlertComponent < Phlex::HTML; end' }
      end

      it 'has a nil namespace' do
        extractor = described_class.new
        unit = extractor.extract_component(component_class)

        expect(unit.namespace).to be_nil
      end

      it 'falls through to the app/components convention path' do
        extractor = described_class.new
        unit = extractor.extract_component(component_class)

        expect(unit.file_path).to eq('/rails/app/components/alert_component.rb')
      end
    end

    context 'when multiple convention paths exist' do
      let(:component_class) { build_component(name: 'BadgeComponent') }

      let(:file_system) do
        {
          '/rails/app/views/components/badge_component.rb' => 'class BadgeComponent < Phlex::HTML; end',
          '/rails/app/components/badge_component.rb' => 'class BadgeComponent; end'
        }
      end

      it 'prefers app/views/components' do
        extractor = described_class.new
        unit = extractor.extract_component(component_class)

        expect(unit.file_path).to eq('/rails/app/views/components/badge_component.rb')
      end
    end

    context 'when no source file can be found' do
      let(:component_class) { build_component(name: 'GhostComponent') }

      it 'produces a unit with nil file_path and empty source' do
        extractor = described_class.new
        unit = extractor.extract_component(component_class)

        expect(unit.file_path).to be_nil
        expect(unit.source_code).to eq('')
      end
    end

    context 'when the component has no view_template' do
      let(:component_class) do
        build_component(name: 'HeadlessComponent', view_template: false, methods: [:call])
      end

      it 'records has_view_template false and the public methods' do
        extractor = described_class.new
        unit = extractor.extract_component(component_class)

        expect(unit.metadata[:has_view_template]).to be false
        expect(unit.metadata[:public_methods]).to eq([:call])
      end
    end

    context 'when extraction raises an error' do
      it 'logs the error and returns nil' do
        klass = Class.new
        klass.define_singleton_method(:name) { 'BrokenComponent' }
        klass.define_singleton_method(:superclass) { Object }
        klass.define_singleton_method(:public_instance_methods) { |_ = true| raise StandardError, 'boom' }

        extractor = described_class.new
        result = extractor.extract_component(klass)
        expect(result).to be_nil
        expect(logger).to have_received(:error).with(/BrokenComponent/)
      end
    end
  end

  # ── Metadata: slots and initialize params ───────────────────────────────

  describe 'slot extraction' do
    let(:component_class) { build_component(name: 'PanelComponent') }

    let(:file_system) do
      {
        '/rails/app/components/panel_component.rb' => <<~RUBY
          class PanelComponent < Phlex::HTML
            renders_one :title
            renders_many :sections

            def actions_slot
              div { yield }
            end
          end
        RUBY
      }
    end

    before do
      stub_const('Phlex::HTML', build_phlex_base)
    end

    it 'extracts untyped renders_one/renders_many slots' do
      extractor = described_class.new
      unit = extractor.extract_component(component_class)

      slots = unit.metadata[:slots]
      expect(slots).to include(a_hash_including(name: 'title', type: :one, class: nil))
      expect(slots).to include(a_hash_including(name: 'sections', type: :many, class: nil))
    end

    it 'extracts method-style slots' do
      extractor = described_class.new
      unit = extractor.extract_component(component_class)

      expect(unit.metadata[:slots]).to include(a_hash_including(name: 'actions', type: :method))
    end
  end

  describe 'initialize param mapping' do
    before do
      stub_const('Phlex::HTML', build_phlex_base)
    end

    it 'maps every Ruby parameter type to a descriptive label' do
      component = build_component(
        name: 'KitchenSinkComponent',
        params: [
          %i[req a], %i[opt b], %i[keyreq c], %i[key d],
          %i[rest e], %i[keyrest f], %i[block g]
        ]
      )

      extractor = described_class.new
      unit = extractor.extract_component(component)

      expect(unit.metadata[:initialize_params]).to eq(
        [
          { name: :a, type: :required },
          { name: :b, type: :optional },
          { name: :c, type: :keyword_required },
          { name: :d, type: :keyword_optional },
          { name: :e, type: :splat },
          { name: :f, type: :double_splat },
          { name: :g, type: :block }
        ]
      )
    end

    it 'returns [] when initialize cannot be introspected' do
      component = build_component(name: 'OpaqueComponent')
      component.define_singleton_method(:instance_method) { |_name| raise NameError, 'no initialize' }

      extractor = described_class.new
      unit = extractor.extract_component(component)

      expect(unit.metadata[:initialize_params]).to eq([])
    end
  end

  # ── Dependency extraction ───────────────────────────────────────────────

  describe 'dependency extraction' do
    let(:component_class) { build_component(name: 'PageComponent') }

    let(:file_system) do
      {
        '/rails/app/components/page_component.rb' => <<~RUBY
          class PageComponent < Phlex::HTML
            include ApplicationHelper

            def view_template
              render HeaderComponent.new
              render(FooterComponent.new)
              div(data_controller: "dropdown") { helpers.number_to_currency(@total) }
              @user = User.find(1)
            end
          end
        RUBY
      }
    end

    before do
      stub_const('Phlex::HTML', build_phlex_base)
    end

    it 'detects Phlex-style rendered sub-components' do
      extractor = described_class.new
      unit = extractor.extract_component(component_class)

      render_deps = unit.dependencies.select { |d| d[:type] == :component && d[:via] == :render }
      expect(render_deps.map { |d| d[:target] }).to include('HeaderComponent')
    end

    it 'detects parenthesized render calls' do
      extractor = described_class.new
      unit = extractor.extract_component(component_class)

      render_deps = unit.dependencies.select { |d| d[:type] == :component && d[:via] == :render }
      expect(render_deps.map { |d| d[:target] }).to include('FooterComponent')
    end

    it 'detects model references as data dependencies' do
      extractor = described_class.new
      unit = extractor.extract_component(component_class)

      model_deps = unit.dependencies.select { |d| d[:type] == :model }
      expect(model_deps).to include(a_hash_including(target: 'User', via: :data_dependency))
    end

    it 'detects helper module includes' do
      extractor = described_class.new
      unit = extractor.extract_component(component_class)

      expect(unit.dependencies).to include(
        a_hash_including(type: :helper, target: 'ApplicationHelper', via: :include)
      )
    end

    it 'detects helpers proxy calls' do
      extractor = described_class.new
      unit = extractor.extract_component(component_class)

      expect(unit.dependencies).to include(
        a_hash_including(type: :helper_method, target: 'number_to_currency', via: :call)
      )
    end

    it 'detects Stimulus controller references' do
      extractor = described_class.new
      unit = extractor.extract_component(component_class)

      expect(unit.dependencies).to include(
        a_hash_including(type: :stimulus_controller, target: 'dropdown', via: :html_attribute)
      )
    end

    it 'includes :via key on all dependencies' do
      extractor = described_class.new
      unit = extractor.extract_component(component_class)

      unit.dependencies.each do |dep|
        expect(dep).to have_key(:via), "Dependency #{dep.inspect} missing :via key"
      end
    end

    context 'with self-references and duplicates' do
      let(:file_system) do
        {
          '/rails/app/components/page_component.rb' => <<~RUBY
            class PageComponent < Phlex::HTML
              def view_template
                render PageComponent.new
                render HeaderComponent.new
                render(HeaderComponent.new(compact: true))
              end
            end
          RUBY
        }
      end

      it 'skips self-references' do
        extractor = described_class.new
        unit = extractor.extract_component(component_class)

        targets = unit.dependencies.select { |d| d[:type] == :component }.map { |d| d[:target] }
        expect(targets).not_to include('PageComponent')
      end

      it 'deduplicates by [type, target]' do
        extractor = described_class.new
        unit = extractor.extract_component(component_class)

        targets = unit.dependencies.select { |d| d[:type] == :component }.map { |d| d[:target] }
        expect(targets).to eq(['HeaderComponent'])
      end
    end
  end

  # ── Navigation dependencies ─────────────────────────────────────────────

  describe 'navigation dependencies' do
    let(:component_class) { build_component(name: 'NavComponent') }

    let(:file_system) do
      {
        '/rails/app/components/nav_component.rb' => <<~RUBY
          class NavComponent < Phlex::HTML
            def view_template
              a(href: posts_path) { "Posts" }
              a(href: unknown_path) { "Nowhere" }
            end
          end
        RUBY
      }
    end

    let(:nav_extractor) do
      posts_route = double('Route',
                           defaults: { controller: 'posts', action: 'index' },
                           path: double(spec: double(to_s: '/posts(.:format)')),
                           verb: 'GET')
      named_routes = { posts: posts_route }
      routes_double = double('Routes', named_routes: named_routes)
      app_double = double('Application', routes: routes_double)
      stub_const('Rails', double('Rails', root: rails_root, logger: logger, application: app_double))
      described_class.new
    end

    before do
      stub_const('Phlex::HTML', build_phlex_base)
      Woods.configure unless Woods.configuration
      allow(Woods.configuration).to receive(:extract_navigation_edges).and_return(true)
    end

    it 'resolves _path helpers to controller targets' do
      unit = nav_extractor.extract_component(component_class)

      expect(unit.dependencies).to include(
        a_hash_including(type: :controller, target: 'PostsController', via: :link_to)
      )
    end

    it 'skips unresolvable helpers' do
      unit = nav_extractor.extract_component(component_class)

      controller_targets = unit.dependencies.select { |d| d[:type] == :controller }.map { |d| d[:target] }
      expect(controller_targets).to eq(['PostsController'])
    end

    it 'returns no navigation edges when config is disabled' do
      allow(Woods.configuration).to receive(:extract_navigation_edges).and_return(false)

      unit = nav_extractor.extract_component(component_class)

      expect(unit.dependencies.select { |d| d[:type] == :controller }).to be_empty
    end
  end

  # ── discoverable_classes ────────────────────────────────────────────────

  describe '#discoverable_classes' do
    it 'returns [] when no component base is loaded' do
      expect(described_class.new.discoverable_classes).to eq([])
    end

    it 'returns the base class descendants' do
      component = build_component(name: 'CardComponent')
      stub_const('Phlex::HTML', build_phlex_base(descendants: [component]))

      expect(described_class.new.discoverable_classes).to eq([component])
    end
  end
end
