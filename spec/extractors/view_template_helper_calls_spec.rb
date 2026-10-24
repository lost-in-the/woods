# frozen_string_literal: true

require 'spec_helper'
require 'set'
require 'tmpdir'
require 'fileutils'
require 'woods'
require 'woods/extractors/view_template_extractor'

RSpec.describe Woods::Extractors::ViewTemplateExtractor, 'helper call edges' do
  include_context 'extractor setup'

  def unit(identifier, extractor: described_class.new)
    extractor.extract_all.find { |candidate| candidate.identifier == identifier }
  end

  def helper_edges(unit)
    unit.dependencies.select { |dependency| %i[helper_call helper_method].include?(dependency[:via]) }
  end

  before do
    create_file('app/helpers/date_helper.rb', <<~RUBY)
      module DateHelper
        def pretty_date(value) = value.to_s
        def short_date(value) = value.to_s
      end
    RUBY
    create_file('app/helpers/ledgers/widgets_helper.rb', <<~RUBY)
      module Ledgers
        module WidgetsHelper
          def widget_badge(widget) = widget.to_s
        end
      end
    RUBY
  end

  it 'links an ERB template to the helper module whose method it calls' do
    create_file('app/views/widgets/show.html.erb', "<h1><%= pretty_date(@widget.shipped_at) %></h1>\n")

    show = unit('widgets/show.html.erb')
    expect(helper_edges(show)).to eq([{ type: :poro, target: 'DateHelper', via: :helper_call }])
    expect(show.metadata[:helper_calls]).to eq('DateHelper' => %w[pretty_date])
  end

  it 'lists every called method under its module, across modules' do
    create_file('app/views/widgets/index.html.erb', <<~ERB)
      <% @widgets.each do |widget| %>
        <%= widget_badge(widget) %> <%= short_date(widget.made_at) %> <%= pretty_date(widget.shipped_at) %>
      <% end %>
    ERB

    index = unit('widgets/index.html.erb')
    expect(helper_edges(index)).to eq([{ type: :poro, target: 'DateHelper', via: :helper_call },
                                       { type: :poro, target: 'Ledgers::WidgetsHelper', via: :helper_call }])
    expect(index.metadata[:helper_calls])
      .to eq('DateHelper' => %w[pretty_date short_date], 'Ledgers::WidgetsHelper' => %w[widget_badge])
  end

  it 'links HAML and jbuilder templates the same way' do
    create_file('app/views/widgets/show.html.haml', "%h1= pretty_date(@widget.shipped_at)\n%p short_date\n")
    create_file('app/views/widgets/show.json.jbuilder', "json.shipped short_date(@widget.shipped_at)\n")
    extractor = described_class.new

    expect(unit('widgets/show.html.haml', extractor: extractor).metadata[:helper_calls])
      .to eq('DateHelper' => %w[pretty_date])
    expect(unit('widgets/show.json.jbuilder', extractor: extractor).metadata[:helper_calls])
      .to eq('DateHelper' => %w[short_date])
  end

  it 'never matches Rails built-ins, markup text, or template locals' do
    create_file('app/views/widgets/_row.html.erb', <<~ERB)
      <%# locals: (short_date:) -%>
      <td title="pretty_date"><%= link_to t('.label'), widget_path(widget) %></td>
      <td><%= short_date %> <%= render 'badge', widget: widget %></td>
    ERB

    row = unit('widgets/_row.html.erb')
    expect(helper_edges(row)).to eq([])
    expect(row.metadata).not_to have_key(:helper_calls)
  end

  it 'links an ambiguous name to each candidate and says so in metadata' do
    create_file('app/helpers/ledgers_helper.rb', "module LedgersHelper\n  def pretty_date(v) = v\nend\n")
    create_file('app/views/ledgers/show.html.erb', '<%= pretty_date(@ledger.closed_at) %>')

    show = unit('ledgers/show.html.erb')
    expect(helper_edges(show).map { |edge| edge[:target] }).to eq(%w[DateHelper LedgersHelper])
    expect(show.metadata[:ambiguous_helper_calls]).to eq('pretty_date' => %w[DateHelper LedgersHelper])
  end

  it 'links a helper_method name to the controller that declares it' do
    helpers = Module.new { def current_widget = nil }
    controller = Class.new do
      define_singleton_method(:name) { 'WidgetsController' }
      define_singleton_method(:_helpers) { helpers }
    end
    create_file('app/views/layouts/application.html.erb', '<%= current_widget.name %> <%= pretty_date(now) %>')
    extractor = described_class.new
    catalog = Woods::Extractors::HelperCatalog.new(root: rails_root, contexts: [controller],
                                                   default_context: controller)
    extractor.instance_variable_set(:@helper_catalog, catalog)

    layout = unit('layouts/application.html.erb', extractor: extractor)
    expect(helper_edges(layout)).to eq([{ type: :poro, target: 'DateHelper', via: :helper_call },
                                        { type: :controller, target: 'WidgetsController', via: :helper_method }])
    expect(layout.metadata[:helper_method_calls]).to eq('WidgetsController' => %w[current_widget])
  end

  it 'emits byte-identical units on a repeat run' do
    create_file('app/views/widgets/show.html.erb', '<%= short_date(a) %><%= pretty_date(b) %><%= widget_badge(c) %>')

    first, second = Array.new(2) { JSON.generate(unit('widgets/show.html.erb').to_h.except(:extracted_at)) }
    expect(first).to eq(second)
  end

  it 'builds the catalog once per extractor, not once per template' do
    3.times { |n| create_file("app/views/widgets/t#{n}.html.erb", '<%= pretty_date(x) %>') }
    allow(Woods::Extractors::HelperCatalog).to receive(:new).and_call_original

    described_class.new.extract_all
    expect(Woods::Extractors::HelperCatalog).to have_received(:new).once
  end

  it 'leaves a template untouched when the app defines no helpers' do
    FileUtils.rm_rf(File.join(tmp_dir, 'app/helpers'))
    create_file('app/views/widgets/show.html.erb', '<%= pretty_date(x) %>')

    show = unit('widgets/show.html.erb')
    expect(show.metadata.keys).to eq(%i[template_engine is_partial partials_rendered instance_variables
                                        helpers_called loc partial_renders])
    expect(show.dependencies).to eq([])
  end
end
