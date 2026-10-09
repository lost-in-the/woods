# frozen_string_literal: true

require 'spec_helper'
require 'woods/extractors/render_target_resolver'

RSpec.describe Woods::Extractors::RenderTargetResolver do
  subject(:resolver) { described_class.new }

  let(:page) { Billing::V2::ManagePage }

  before do
    stub_const('Phlex::Kit', Module.new)
    stub_const('Phlex::HTML', Class.new)
    stub_const('ApplicationView', Class.new(Phlex::HTML))

    stub_const('Ui', Module.new.tap { |kit| kit.extend(Phlex::Kit) })
    %w[Header NavMenu NavItem].each do |name|
      stub_const("Ui::#{name}", Class.new(Phlex::HTML) { include Ui })
    end

    stub_const('Billing::V2::TierGrid', Class.new(ApplicationView))
    stub_const('Billing::V2::ManagePage', Class.new(ApplicationView) { include Ui })
  end

  def nested(body)
    <<~RUBY
      module Billing
        module V2
          class ManagePage < ApplicationView
            include Ui

            def view_template
              #{body}
            end
          end
        end
      end
    RUBY
  end

  def resolve(body, component: page)
    resolver.call(component, nested(body))
  end

  describe 'rendered constants' do
    it 'qualifies a sibling through the lexical scope of the rendering class' do
      expect(resolve('render TierGrid.new(tiers)').targets).to eq(['Billing::V2::TierGrid'])
    end

    it 'prefers the lexical scope over a same-named top-level component' do
      stub_const('TierGrid', Class.new(ApplicationView))

      expect(resolve('render TierGrid.new').targets).to eq(['Billing::V2::TierGrid'])
    end

    it 'does not search enclosing modules for a compact declaration' do
      source = "class Billing::V2::ManagePage < ApplicationView\n  def view_template = render(TierGrid.new)\nend\n"

      result = resolver.call(page, source)

      expect(result.targets).to eq([])
      expect(result.unresolved).to eq([{ name: 'TierGrid', reason: 'constant_missing' }])
    end

    it 'reaches a Kit component through the ancestors of the rendering class' do
      expect(resolve('render Header.new').targets).to eq(['Ui::Header'])
    end

    it 'falls back to the top level' do
      stub_const('Footer', Class.new(ApplicationView))

      expect(resolve('render Footer.new').targets).to eq(['Footer'])
    end

    it 'keeps an already qualified target' do
      expect(resolve('render Ui::NavMenu.new').targets).to eq(['Ui::NavMenu'])
    end

    it 'records a constant that resolves to nothing and emits no target' do
      result = resolve('render Ghost.new')

      expect(result.targets).to eq([])
      expect(result.unresolved).to eq([{ name: 'Ghost', reason: 'constant_missing' }])
    end

    it 'records a constant that is not a component class' do
      stub_const('Billing::V2::Ledger', Class.new)

      expect(resolve('render Ledger.new').unresolved).to eq([{ name: 'Ledger', reason: 'not_a_component' }])
    end

    it 'never autoloads to name a target' do
      Billing::V2.autoload(:Lazy, '/nonexistent/woods/lazy.rb')

      expect(resolve('render Lazy.new').unresolved).to eq([{ name: 'Lazy', reason: 'autoload_pending' }])
    end

    it 'omits a component rendering itself' do
      result = resolve('render ManagePage.new')

      expect(result.targets).to eq([])
      expect(result.unresolved).to eq([])
    end

    it 'follows an aliased constant to the component it names' do
      stub_const('Billing::V2::Card', Ui::Header)

      result = resolve('render Card.new')

      expect(result.targets).to eq(['Ui::Header'])
      expect(result.unresolved).to eq([])
    end

    it 'follows an aliased namespace inside a constant path' do
      stub_const('Billing::V2::Parts', Ui)

      expect(resolve('render Parts::NavMenu.new').targets).to eq(['Ui::NavMenu'])
    end

    it 'records an alias of something that is not a component' do
      stub_const('Billing::V2::Tally', Class.new)
      stub_const('Billing::V2::Count', Billing::V2::Tally)

      expect(resolve('render Count.new').unresolved).to eq([{ name: 'Count', reason: 'not_a_component' }])
    end

    it 'counts a ViewComponent as a component class' do
      stub_const('ViewComponent::Base', Class.new)
      stub_const('Billing::V2::SummaryComponent', Class.new(ViewComponent::Base))

      expect(resolve('render SummaryComponent.new').targets).to eq(['Billing::V2::SummaryComponent'])
    end
  end

  describe 'Kit calls' do
    it 'resolves a capitalized call through a Kit the class includes' do
      expect(resolve('Header(title: "x")').targets).to eq(['Ui::Header'])
    end

    it 'resolves through a Kit only an ancestor includes' do
      stub_const('ApplicationView', Class.new(Phlex::HTML) { include Ui })
      stub_const('Billing::V2::Receipt', Class.new(ApplicationView))

      source = <<~RUBY
        module Billing
          module V2
            class Receipt < ApplicationView
              def view_template = Header(title: "x")
            end
          end
        end
      RUBY

      expect(resolver.call(Billing::V2::Receipt, source).targets).to eq(['Ui::Header'])
    end

    it 'does not take a lexical sibling for a Kit call, which is a method lookup' do
      stub_const('Billing::V2::Header', Class.new(ApplicationView))

      expect(resolve('Header(title: "x")').targets).to eq(['Ui::Header'])
    end

    it 'accepts a module that defines the call as a method without extending Phlex::Kit' do
      stub_const('Parts', Module.new { define_method(:Chip) { |*| nil } }) # rubocop:disable Naming/MethodName
      stub_const('Parts::Chip', Class.new(ApplicationView))
      stub_const('Billing::V2::ManagePage', Class.new(ApplicationView) { include Parts })

      expect(resolve('Chip("a")').targets).to eq(['Parts::Chip'])
    end

    it 'follows a Kit constant that aliases a component elsewhere' do
      stub_const('Ui::Tile', Billing::V2::TierGrid)

      expect(resolve('Tile(1)').targets).to eq(['Billing::V2::TierGrid'])
    end

    it 'resolves a call on a named Kit module' do
      stub_const('Billing::V2::ManagePage', Class.new(ApplicationView))

      expect(resolve('Ui::Header(title: "x")').targets).to eq(['Ui::Header'])
    end

    it 'resolves a call on a block argument through the Kits of the class' do
      result = resolve('render Ui::NavMenu.new { |m| m.NavItem("a") }')

      expect(result.targets).to eq(%w[Ui::NavItem Ui::NavMenu])
    end

    it 'resolves a call on a block argument through the Kits of the components the file renders' do
      stub_const('Billing::V2::ManagePage', Class.new(ApplicationView))

      result = resolve('render Ui::NavMenu.new { |m| m.NavItem("a") }')

      expect(result.targets).to eq(%w[Ui::NavItem Ui::NavMenu])
    end

    it 'records a capitalized call no Kit provides' do
      result = resolve('Sidebar(open: true)')

      expect(result.targets).to eq([])
      expect(result.unresolved).to eq([{ name: 'Sidebar', reason: 'no_kit_constant' }])
    end

    it 'records a block-argument call no Kit provides' do
      expect(resolve('m.Sidebar(1)').unresolved).to eq([{ name: 'Sidebar', reason: 'no_kit_constant' }])
    end

    it 'treats an ordinary capitalized method as neither a target nor unresolved' do
      stub_const('Mailbox', Module.new { define_singleton_method(:Address) { |*| nil } }) # rubocop:disable Naming/MethodName

      result = resolve('Integer("3"); Array(rows); Mailbox::Address("a")')

      expect(result.targets).to eq([])
      expect(result.unresolved).to eq([])
    end
  end

  describe 'components the application does not own' do
    subject(:resolver) do
      described_class.new(ownership: lambda { |klass|
        { Ui::Header => 'shelf_ui', Ui::NavMenu => nil }.fetch(klass, :app)
      })
    end

    it 'reports them as external with their gem and emits no target' do
      result = resolve('Header(title: "x"); render Ui::NavMenu.new; render TierGrid.new')

      expect(result.targets).to eq(['Billing::V2::TierGrid'])
      expect(result.external).to eq([{ name: 'Ui::Header', gem: 'shelf_ui' }, { name: 'Ui::NavMenu', gem: nil }])
      expect(result.unresolved).to eq([])
    end

    it 'still resolves a yielded call through the Kits of an external component' do
      stub_const('Billing::V2::ManagePage', Class.new(ApplicationView))

      result = resolve('render Ui::NavMenu.new { |m| m.NavItem("a") }')

      expect(result.targets).to eq(['Ui::NavItem'])
    end
  end

  describe 'slot declarations' do
    def declare(body)
      resolver.call(page, <<~RUBY)
        module Billing
          module V2
            class ManagePage < ApplicationView
              #{body}
            end
          end
        end
      RUBY
    end

    it 'resolves a slot constant like a rendered constant, apart from the render targets' do
      result = declare('renders_one :grid, TierGrid')

      expect(result.slot_targets).to eq(['Billing::V2::TierGrid'])
      expect(result.targets).to eq([])
    end

    it 'resolves a string class name from the component class, not its lexical scope' do
      stub_const('Footer', Class.new(ApplicationView))

      result = declare('renders_many :rows, "TierGrid"; renders_one :footer, "Footer"; renders_one :head, "Header"')

      expect(result.slot_targets).to eq(%w[Footer Ui::Header])
      expect(result.unresolved_slots).to eq([{ name: 'TierGrid', reason: 'constant_missing' }])
    end

    it 'resolves the component a lambda slot builds' do
      expect(declare('renders_one :grid, ->(**args) { TierGrid.new(**args) }').slot_targets)
        .to eq(['Billing::V2::TierGrid'])
    end

    it 'records a slot that names no component and emits no target' do
      stub_const('Billing::V2::Ledger', Class.new)

      result = declare('renders_one :a, Ghost; renders_one :b, Ledger')

      expect(result.slot_targets).to eq([])
      expect(result.unresolved_slots).to eq(
        [{ name: 'Ghost', reason: 'constant_missing' }, { name: 'Ledger', reason: 'not_a_component' }]
      )
      expect(result.unresolved).to eq([])
    end

    it 'reports a slot component the application does not own as external' do
      resolver = described_class.new(ownership: ->(klass) { klass == Ui::Header ? 'shelf_ui' : :app })

      result = resolver.call(page, "class Billing::V2::ManagePage\n  renders_one :head, Ui::Header\nend\n")

      expect(result.slot_targets).to eq([])
      expect(result.external).to eq([{ name: 'Ui::Header', gem: 'shelf_ui' }])
    end
  end

  describe 'template fragments' do
    let(:class_source) { "module Billing\n  module V2\n    class ManagePage < ApplicationView\n    end\n  end\nend\n" }

    def render_fragments(*fragments)
      resolver.call(page, class_source, fragments: fragments)
    end

    it 'resolves renders and Kit calls in fragments, each parsed on its own' do
      result = render_fragments(' render Ui::NavMenu.new do |menu| ', ' menu.NavItem("a") ', ' end ', ' Header() ')

      expect(result.targets).to eq(%w[Ui::Header Ui::NavItem Ui::NavMenu])
      expect(result.unresolved).to eq([])
    end

    it 'looks a constant up from the component class alone, as a compiled template does' do
      result = render_fragments('render TierGrid.new', 'render Billing::V2::TierGrid.new', 'render Header.new')

      expect(result.targets).to eq(%w[Billing::V2::TierGrid Ui::Header])
      expect(result.unresolved).to eq([{ name: 'TierGrid', reason: 'constant_missing' }])
    end

    it 'takes no slot declaration from a template' do
      result = render_fragments('renders_one :grid, Billing::V2::TierGrid')

      expect(result.slot_targets).to eq([])
    end
  end

  it 'resolves only the requested kinds of call' do
    stub_const('Billing::V2::ManagePage', Class.new(ApplicationView))
    source = nested('render TierGrid.new; Sidebar(1); m.Sidebar(2)')

    result = resolver.call(page, source, kinds: %i[constant])

    expect(result.targets).to eq(['Billing::V2::TierGrid'])
    expect(result.unresolved).to eq([])
  end

  it 'never reports a lowercase helper call' do
    result = resolve('form_with(model: @x) { }; t(".title"); partial("x"); render partial("x")')

    expect(result.targets).to eq([])
    expect(result.unresolved).to eq([])
  end

  it 'returns sorted, distinct targets and unresolved names' do
    result = resolve('render TierGrid.new; Header(); render Zed.new; render Ghost.new; render TierGrid.new; Header()')

    expect(result.targets).to eq(%w[Billing::V2::TierGrid Ui::Header])
    expect(result.unresolved.map { |entry| entry[:name] }).to eq(%w[Ghost Zed])
  end

  it 'resolves at the top level when the rendering class is not a loaded constant' do
    stub_const('Footer', Class.new(ApplicationView))
    anonymous = Class.new(ApplicationView)

    source = "class Unloaded < ApplicationView\n  def view_template = render(Footer.new)\nend\n"

    result = resolver.call(anonymous, source)

    expect(result.targets).to eq(['Footer'])
  end

  it 'does not call application overrides of reflection methods' do
    Billing::V2::TierGrid.define_singleton_method(:name) { raise 'must never execute' }
    Billing::V2::TierGrid.define_singleton_method(:ancestors) { raise 'must never execute' }

    expect(resolve('render TierGrid.new').targets).to eq(['Billing::V2::TierGrid'])
  end
end
