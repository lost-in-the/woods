# frozen_string_literal: true

require 'spec_helper'
require 'timeout'
require 'woods/extractors/render_call_scan'

RSpec.describe Woods::Extractors::RenderCallScan do
  def scan(source)
    described_class.call(source).map { |candidate| [candidate.kind, candidate.name, candidate.nesting] }
  end

  it 'reports a rendered constant with the lexical nesting of its call site' do
    source = <<~RUBY
      module Billing
        module V2
          class ManagePage < ApplicationView
            def view_template
              render TierGrid.new(tiers)
            end
          end
        end
      end
    RUBY

    expect(scan(source)).to eq([[:constant, 'TierGrid', %w[Billing::V2::ManagePage Billing::V2 Billing]]])
  end

  it 'keeps a compact declaration as one nesting entry' do
    source = "class Billing::V2::ManagePage < ApplicationView\n  def view_template = render(TierGrid.new)\nend\n"

    expect(scan(source)).to eq([[:constant, 'TierGrid', %w[Billing::V2::ManagePage]]])
  end

  it 'reports every render argument shape that names a component constant' do
    source = <<~RUBY
      class Page
        def view_template
          render Ui::NavMenu.new(compact: true)
          render(Ledger.with_collection(rows))
          render Widget.new(1).with_content("x")
          render ::Shipment
          helpers.render Footer.new
        end
      end
    RUBY

    expect(scan(source).map { |kind, name, _| [kind, name] }).to eq(
      [[:constant, 'Ui::NavMenu'], [:constant, 'Ledger'], [:constant, 'Widget'],
       [:constant, '::Shipment'], [:constant, 'Footer']]
    )
  end

  it 'separates bare, module-qualified, and yielded capitalized calls' do
    source = <<~RUBY
      class Page
        def view_template
          Header(title: "x")
          Ui::Badge("new")
          render Ui::NavMenu.new { |m| m.NavItem("a") }
        end
      end
    RUBY

    expect(scan(source).map { |kind, name, _| [kind, name] }).to eq(
      [[:kit, 'Header'], [:kit_path, 'Ui::Badge'], [:constant, 'Ui::NavMenu'], [:yielded, 'NavItem']]
    )
  end

  it 'reports the component each slot declaration names, in every form' do
    source = <<~RUBY
      module Ledger
        class PageComponent < ViewComponent::Base
          renders_one :title
          renders_one :header, HeaderComponent
          renders_many :rows, "RowComponent"
          renders_one :footer, ->(**args) { FooterComponent.new(**args) }
          renders_one :aside, lambda { |label| Ui::Aside.new(label) }
          renders_one :body, ->(text) { text.upcase }
          renders_many :items, types: {
            chip: ChipComponent,
            tag: "TagComponent",
            link: { renders: LinkComponent, as: :link },
            note: ->(text) { NoteComponent.new(text) }
          }
        end
      end
    RUBY

    expect(scan(source)).to eq(
      [[:slot, 'HeaderComponent', %w[Ledger::PageComponent Ledger]],
       [:slot_string, 'RowComponent', %w[Ledger::PageComponent]],
       [:slot, 'FooterComponent', %w[Ledger::PageComponent Ledger]],
       [:slot, 'Ui::Aside', %w[Ledger::PageComponent Ledger]],
       [:slot, 'ChipComponent', %w[Ledger::PageComponent Ledger]],
       [:slot_string, 'TagComponent', %w[Ledger::PageComponent]],
       [:slot, 'LinkComponent', %w[Ledger::PageComponent Ledger]],
       [:slot, 'NoteComponent', %w[Ledger::PageComponent Ledger]]]
    )
  end

  it 'never reports a lowercase call, a helper argument, or a non-constant render' do
    source = <<~RUBY
      class Page
        def view_template
          form_with(model: @x) { }
          t(".title")
          partial("x")
          render partial("x")
          render @widget
          render "shared/menu"
          render widget.new
        end
      end
    RUBY

    expect(scan(source)).to eq([])
  end

  it 'ignores render text inside comments, strings, and heredocs' do
    source = <<~RUBY
      class Page
        # render Ghost.new
        NOTE = "render Phantom.new"
        DOC = <<~TEXT
          Header(title: "x")
        TEXT
      end
    RUBY

    expect(scan(source)).to eq([])
  end

  it 'attributes each call in a multi-class file to its own nesting' do
    source = <<~RUBY
      module Ui
        class Card < Base
          def view_template = Badge("a")
        end
        class Panel < Base
          def view_template = Badge("b")
        end
      end
    RUBY

    expect(scan(source).map(&:last)).to eq([%w[Ui::Card Ui], %w[Ui::Panel Ui]])
  end

  it 'returns the candidates it can still read from source that does not parse' do
    expect(scan("class Page\n  def view_template\n    render Widget.new\n")).to eq([[:constant, 'Widget', %w[Page]]])
  end

  describe 'adversarial input' do
    # No pattern here can backtrack: the scan is a Prism tree walk and its one
    # regex is a single anchored character class. These pin linear behavior.
    around do |example|
      if Regexp.respond_to?(:timeout=)
        previous = Regexp.timeout
        Regexp.timeout = 1
        begin
          example.run
        ensure
          Regexp.timeout = previous
        end
      else
        Timeout.timeout(5) { example.run }
      end
    end

    it 'scans 50,000 repeated renders' do
      source = "class Page\n  def view_template\n#{"    render Widget.new\n" * 50_000}  end\nend\n"

      expect(described_class.call(source).size).to eq(50_000)
    end

    it 'scans 10,000 near-matches without reporting one' do
      near = "    render widget.new; header(1); m.nav_item\n" * 10_000
      source = "class Page\n  def view_template\n#{near}  end\nend\n"

      expect(described_class.call(source)).to eq([])
    end

    it 'declines source nested too deeply to walk instead of raising' do
      source = "#{'render(' * 50_000}Widget.new#{')' * 50_000}"

      expect { described_class.call(source) }.not_to raise_error
    end
  end
end
