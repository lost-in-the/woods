# frozen_string_literal: true

require 'spec_helper'
require 'fileutils'
require 'json'
require 'tmpdir'
require 'woods/mcp/server'

# The rules, over the whole text of a lookup in the Markdown, Claude and
# plain formats, on one page and paged: no value is printed as a Ruby
# `inspect` of a Hash or Array, and a value that says nothing (nil, "", [],
# {}, or a list or object holding only those) prints no key at all. `false`
# and `0` are answers and are printed. Text that holds ` => ` itself (source,
# a string value) is left as it is.
RSpec.describe 'lookup text of a unit with nested and empty values' do
  # Made-up names. Each name containing "empty" or "blank" holds nothing.
  let(:source) do
    "class WidgetsController < ApplicationController\n  " \
      "OPTIONS = { \"mode\" => \"fast\" }.freeze\n" \
      "#{Array.new(120) { |index| "  def action_#{index}; end\n" }.join}end\n"
  end
  let(:metadata) do
    {
      'routes' => {
        'show' => [{ 'verb' => 'GET', 'path' => '/widgets/:id', 'blank_name' => '', 'empty_constraints' => {},
                     'blank_as' => nil, 'blank_defaults' => { 'format' => nil } }, {}],
        'empty_route' => [], 'empty_routes' => [{}, { 'blank_verb' => '' }]
      },
      'filters' => [
        { 'name' => 'require_login', 'only' => %w[show], 'note' => 'maps key => value',
          'options' => { 'if' => 'signed_in?', 'blank_option' => nil },
          'conditions' => [{ 'kind' => 'if', 'blank_source' => '' }, { 'empty_args' => [] }] }, {}
      ],
      'actions' => %w[index show],
      'pattern' => 'a => b',
      'blank_text' => '', 'empty_nil' => nil, 'empty_list' => [], 'empty_object' => {},
      'empty_items' => [{}, '', nil, { 'blank_leaf' => [] }],
      'empty_nested' => { 'blank_inner' => '', 'empty_inner_list' => [], 'blank_deeper' => { 'leaf' => nil } },
      'settings' => { 'zero_count' => 0, 'enabled' => false, 'blank_note' => '',
                      'mapping' => { 'outer' => { 'inner' => 'deep' }, 'blank_mapping' => {} } }
    }
  end
  let(:unit) do
    { 'type' => 'controller', 'identifier' => 'PostsController', 'file_path' => 'app/controllers/widgets.rb',
      'namespace' => nil, 'source_code' => source, 'metadata' => metadata,
      'dependencies' => [{ 'target' => 'Widget', 'type' => 'model', 'via' => 'code_reference' }, 'Gear'],
      'dependents' => [{ 'identifier' => 'AdminWidgetsController', 'type' => 'controller', 'via' => 'inheritance' }] }
  end

  # The rendered text minus the unit's source, which is printed verbatim.
  def expect_readable(text)
    expect(text).to include(source.chomp)
    rest = text.sub(source.chomp, '')
    expect(rest).not_to match(/"\s*=>/) # Hash#inspect: `{"k"=>v}` (Ruby < 3.4) or `{"k" => v}`
    expect(rest).not_to match(/\{"|\["/)
    expect(rest).not_to match(/empty|blank/)
    expect_kept(rest)
  end

  def expect_kept(rest)
    expect(rest).to include('maps key => value').and include('a => b')
    expect(rest).to match(/zero_count[:=] ?0/).and match(/enabled[:=] ?false/)
    expect(rest).to include('inner: deep').and include('verb: GET').and include('if: signed_in?')
    expect(rest).to include('Widget').and include('Gear').and include('AdminWidgetsController')
  end

  # No line is a key with nothing after it unless list items follow it, and
  # no list item or `name=value` pair is empty.
  def expect_no_bare_keys(text)
    lines = text.lines.map(&:chomp)
    lines.each_with_index do |line, index|
      expect(line).not_to match(/\A\s*-\s*\z/)
      expect(line).not_to match(/\w=(,|\z)/)
      next unless line.match?(/\A(\*\*[^*]+:\*\*|\s+\w+:)\s*\z/)

      expect(lines[index + 1]).to match(/\A\s+- \S/), "bare key line: #{line.inspect}"
    end
  end

  %i[markdown claude plain].each do |format|
    describe "the #{format} format" do
      it 'renders the whole unit readably' do
        text = Woods::MCP::ToolResponseRenderer.for(format).render(:lookup, unit)

        expect_readable(text)
        expect_no_bare_keys(text)
      end

      it 'prints no metadata heading when no metadata value says anything' do
        empty = unit.merge('metadata' => metadata.slice('blank_text', 'empty_items', 'empty_nested'))
        text = Woods::MCP::ToolResponseRenderer.for(format).render(:lookup, empty)

        expect(text).not_to match(/metadata/i)
      end
    end
  end

  describe 'through the lookup tool' do
    let(:index_dir) { Dir.mktmpdir('woods-lookup-text-values') }

    before do
      FileUtils.cp_r(File.join(File.expand_path('../fixtures/woods', __dir__), '.'), index_dir)
      path = Dir[File.join(index_dir, 'controllers', 'PostsController*.json')].first
      File.write(path, JSON.generate(unit))
    end

    after { FileUtils.rm_rf(index_dir) }

    def lookup(format, **arguments)
      server = Woods::MCP::Server.build(index_dir: index_dir, response_format: format, warmup: false)
      server.instance_variable_get(:@tools).fetch('lookup')
            .call(identifier: 'PostsController', **arguments, server_context: {})
    end

    def text(response)
      response.content.first[:text]
    end

    # The page's own characters, between its position lines.
    def body(response)
      position = response.meta.fetch(:lookup_page)
      text(response).lines[1...-1].join[0, position[:last_char] - position[:first_char] + 1]
    end

    %i[markdown claude plain].each do |format|
      it "answers the #{format} format readably on one page" do
        response = lookup(format, max_chars: 2_000_000)

        expect(response.error?).to be(false)
        expect(text(response)).not_to include('lookup page')
        expect_readable(text(response))
        expect_no_bare_keys(text(response))
      end

      it "answers the #{format} format readably in pages" do
        first = lookup(format, max_chars: 1500)
        where = first.meta.fetch(:lookup_page)
        rest = (2..where[:pages]).map do |number|
          lookup(format, max_chars: 1500, page: number, answer_id: where[:answer_id])
        end
        whole = [first, *rest].map { |response| body(response) }.join

        expect(where[:pages]).to be > 2
        expect_readable(whole)
        expect_no_bare_keys(whole)
      end
    end
  end
end
