# frozen_string_literal: true

require 'spec_helper'
require 'timeout'
require 'woods/extractors/template_ruby_fragments'

RSpec.describe Woods::Extractors::TemplateRubyFragments do
  def fragments(source, engine)
    described_class.call(source, engine: engine).map(&:strip)
  end

  describe 'ERB' do
    it 'returns the Ruby of each output and statement tag' do
      source = <<~ERB
        <div class="page">
          <%= render Ledger::RowComponent.new(row: @row) do |row| %>
            <%- row.with_cell { "x" } -%>
          <% end %>
          <%== Header(title: "x") %>
        </div>
      ERB

      expect(fragments(source, :erb)).to eq(
        ['render Ledger::RowComponent.new(row: @row) do |row|', 'row.with_cell { "x" }', 'end', 'Header(title: "x")']
      )
    end

    it 'skips comment tags, escaped tags, and text outside tags' do
      source = "render Ghost.new\n<%# render Phantom.new %>\n<%% render Spectre.new %>\n<%= t('.title') %>\n"

      expect(fragments(source, :erb)).to eq(["t('.title')"])
    end

    it 'keeps a tag that spans lines whole and drops one that never closes' do
      expect(fragments("<%= render Widget.new(\n  a: 1\n) %>\n<%= render Lost.new", :erb))
        .to eq(["render Widget.new(\n  a: 1\n)"])
    end

    it 'keeps multibyte text out of the way' do
      expect(fragments("<p>café ☕</p><%= render Widget.new(label: 'é') %>", :erb))
        .to eq(["render Widget.new(label: 'é')"])
    end
  end

  describe 'HAML' do
    it 'returns the Ruby of script lines and of scripts attached to a tag' do
      source = <<~HAML
        .page
          = render Ledger::RowComponent.new(row: @row) do |row|
            - row.with_cell { "x" }
          %h1{class: "title", data: {kind: "a"}}= Header(title: "x")
          %span.label(id="a")!= render Widget.new
          #main~ render Ledger::NoteComponent.new
          plain render Ghost.new
      HAML

      expect(fragments(source, :haml)).to eq(
        ['render Ledger::RowComponent.new(row: @row) do |row|', 'row.with_cell { "x" }', 'Header(title: "x")',
         'render Widget.new', 'render Ledger::NoteComponent.new']
      )
    end

    it 'joins a script continued across comma-ended lines' do
      source = "= render Widget.new(a: 1,\n  b: 2,\n  c: 3)\n= render Ledger.new\n"

      expect(fragments(source, :haml)).to eq(["render Widget.new(a: 1,\nb: 2,\nc: 3)", 'render Ledger.new'])
    end

    it 'skips silent comment blocks and the bodies of filters that are not Ruby' do
      source = <<~HAML
        -# render Ghost.new
          = render Phantom.new
        :javascript
          = render Spectre.new
        :ruby
          widget = Widget.new
          render widget
        = render Ledger.new
      HAML

      expect(fragments(source, :haml)).to eq(['widget = Widget.new', 'render widget', 'render Ledger.new'])
    end
  end

  it 'returns nothing for an engine it does not read' do
    expect(described_class.call('json.widget render(Widget.new)', engine: :jbuilder)).to eq([])
  end

  describe 'adversarial input' do
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

    it 'reads 50,000 ERB tags' do
      expect(described_class.call('<%= render Widget.new %>' * 50_000, engine: :erb).size).to eq(50_000)
    end

    it 'reads 10,000 unclosed ERB openers without rescanning' do
      expect(described_class.call('<% <%# <%% ' * 10_000, engine: :erb)).to eq([])
    end

    it 'reads 50,000 HAML script lines and 10,000 near-matches' do
      source = ("= render Widget.new\n" * 50_000) + ("%p{a: {b: {c: 1\n" * 10_000)

      expect(described_class.call(source, engine: :haml).size).to eq(50_000)
    end

    it 'reads one HAML tag with 50,000 nested attribute braces' do
      source = "%p#{'{' * 50_000}#{'}' * 50_000}= render Widget.new\n"

      expect(fragments(source, :haml)).to eq(['render Widget.new'])
    end
  end
end
