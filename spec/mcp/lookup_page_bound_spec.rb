# frozen_string_literal: true

require 'spec_helper'
require 'fileutils'
require 'json'
require 'tmpdir'
require 'woods/mcp/server'

# The rule: the text of every lookup page a client receives is at most the
# page limit, counted in characters on exactly the text sent (position
# lines, JSON envelope and escapes included). Checked over generated units
# that stress each way a page could overshoot.
RSpec.describe Woods::MCP::LookupPages, 'page size bound' do
  # Units built to overshoot: escapes, indentation, many small items, wide
  # characters, one string with no line breaks. Names are made up.
  def self.generated_units
    { 'escape-heavy source' => escape_heavy_unit, 'deep nested metadata' => nested_unit,
      'long list of small hashes' => list_unit, 'wide unicode' => unicode_unit,
      'one huge single string' => single_string_unit, 'mixed' => mixed_unit }
  end

  def self.escape_heavy_unit
    random = Random.new(1066)
    lines = Array.new(3000) do |index|
      "  x_#{index} = \"q\\\"#{'\\' * random.rand(1..6)}\"\t# \u0001 \"#{'"' * random.rand(1..9)}\n"
    end
    { 'identifier' => 'Widget', 'type' => 'model', 'source_code' => "class Widget\n#{lines.join}end\n" }
  end

  def self.nested_unit
    metadata = (1..12).reduce({ 'leaf' => "\"#{'\\' * 40}\"\n" * 30 }) do |inner, depth|
      { "level_#{depth}" => inner, "sibling_#{depth}" => 'x' * 90 }
    end
    { 'identifier' => 'Gadget', 'type' => 'service', 'metadata' => metadata }
  end

  def self.list_unit
    methods = Array.new(2500) do |index|
      { 'name' => "method_#{index}", 'line' => index, 'visibility' => 'public', 'args' => ['a', '"b"'] }
    end
    { 'identifier' => 'Sprocket', 'type' => 'model', 'metadata' => { 'methods' => methods } }
  end

  def self.unicode_unit
    source = Array.new(1500) { |index| "# #{index} 日本語のテキスト — café 🚀 \u00e9\u00e8\n" }.join
    { 'identifier' => 'Gizmo', 'type' => 'model', 'source_code' => source }
  end

  def self.single_string_unit
    { 'identifier' => 'Doohickey', 'type' => 'model',
      'source_code' => Array.new(60_000) { |index| index.even? ? '"' : 'é' }.join }
  end

  def self.mixed_unit
    routes = Array.new(400) { |index| { 'verb' => 'GET', 'path' => "/t/#{index}\\\"" } }
    { 'identifier' => 'Thingamajig', 'type' => 'controller',
      'metadata' => { 'routes' => routes, 'notes' => "\u0002\u0003\n" * 2000 },
      'source_code' => "\\n\"\t" * 5000,
      'dependencies' => Array.new(300) { |index| "Dep#{index}" } }
  end

  # Every page of +unit+ in the JSON format, as the lookup tool renders it.
  def json_page_texts(unit, limit)
    whole = JSON.pretty_generate(unit)
    parts = described_class.json_pages(unit, limit)
    answer = described_class.answer_id(whole, limit)
    parts.each_with_index.map do |part, index|
      position = Woods::MCP::LookupPages::Page.new(number: index + 1, pages: parts.size,
                                                   total_chars: whole.length, answer_id: answer)
      described_class.render_json(position, part)
    end
  end

  # Every page of +text+ in a text format, as the lookup tool renders it.
  def text_page_texts(text, limit)
    pages = described_class.page(text, max_chars: limit, number: 1).pages
    (1..pages).map { |number| described_class.render(described_class.page(text, max_chars: limit, number: number)) }
  end

  # 1,000 is the smallest page size a lookup accepts (MIN_MAX_CHARS).
  limits = [1_000, 1_500, 4_000, Woods::MCP::LookupPages::DEFAULT_MAX_CHARS]

  generated_units.each do |name, unit|
    limits.each do |limit|
      it "keeps every JSON page of #{name} within #{limit} characters, parsing, and merging back" do
        bound = limit
        pages = begin
          json_page_texts(unit, bound)
        rescue Woods::MCP::LookupPages::PageTooSmall => e
          # Twelve levels of objects leave a smallest page no room for a
          # value beside its keys: refused, naming a size that holds it.
          raise unless name == 'deep nested metadata' && limit == 1_000

          expect(e.required).to be > limit
          bound = e.required
          json_page_texts(unit, bound)
        end

        expect(pages.map(&:length).max).to be <= bound
        parsed = pages.map { |page| JSON.parse(page) }
        expect(described_class.merge_json_units(parsed.map { |page| page.fetch('unit') })).to eq(unit)
      end

      it "keeps every Markdown page of #{name} within #{limit} characters, losing nothing" do
        text = Woods::MCP::ToolResponseRenderer.for(:markdown).render(:lookup, unit)
        pages = text_page_texts(text, limit)

        expect(pages.map(&:length).max).to be <= limit
        bodies = (1..pages.size).map { |number| described_class.page(text, max_chars: limit, number: number).text }
        expect(bodies.join).to eq(text)
      end
    end
  end

  it 'refuses, naming the page size that would hold it, a list item that no page at the limit can hold' do
    unit = { 'identifier' => 'Widget', 'metadata' => { 'items' => [{ 'blob' => 'x' * 3000 }] } }

    expect { described_class.json_pages(unit, 1_500) }
      .to raise_error(Woods::MCP::LookupPages::PageTooSmall) { |error|
        expect(error.required).to be > 1_500
        expect(json_page_texts(unit, error.required).map(&:length).max).to be <= error.required
      }
  end

  describe '.smallest_max_chars' do
    def json_fits?(unit, size)
      described_class.json_pages(unit, size)
      true
    rescue Woods::MCP::LookupPages::PageTooSmall
      false
    end

    uncuttable = { 'identifier' => 'Widget', 'metadata' => { 'items' => [{ 'blob' => 'x' * 3000 }] } }
    generated_units.merge('one uncuttable list item' => uncuttable).each do |name, unit|
      it "names a JSON page size for #{name} that serves it, when the one below does not" do
        whole = JSON.pretty_generate(unit)
        size = described_class.smallest_max_chars(whole, unit: unit)

        expect(json_page_texts(unit, size).map(&:length).max).to be <= size
        expect(size == Woods::MCP::LookupPages::MIN_MAX_CHARS || !json_fits?(unit, size - 1)).to be(true)
      end
    end

    it 'names the smallest page for a text rendering' do
      text = Woods::MCP::ToolResponseRenderer.for(:markdown).render(:lookup, mixed_unit_for_text)

      expect(described_class.smallest_max_chars(text)).to eq(Woods::MCP::LookupPages::MIN_MAX_CHARS)
    end

    def mixed_unit_for_text
      self.class.mixed_unit
    end
  end

  it 'still answers a unit that fits whole on one page' do
    unit = { 'identifier' => 'Widget', 'metadata' => { 'items' => [{ 'name' => 'a' }] } }

    expect(described_class.json_pages(unit, 1_500).size).to eq(1)
  end

  describe 'through the lookup tool at the default limit' do
    let(:index_dir) { Dir.mktmpdir('woods-lookup-bound') }
    before do
      FileUtils.cp_r(File.join(File.expand_path('../fixtures/woods', __dir__), '.'), index_dir)
      path = Dir[File.join(index_dir, 'models', 'Post*.json')].first
      post = JSON.parse(File.read(path, encoding: 'UTF-8'))
      source = "class Post\n#{Array.new(6000) { |index| "  x_#{index} = \"\\\\\\\"\t\u0001\"\n" }.join}end\n"
      methods = Array.new(3000) { |index| { 'name' => "m_#{index}", 'line' => index, 'args' => ['"a"'] } }
      post['metadata'] = post.fetch('metadata').merge('methods' => methods)
      File.write(path, JSON.generate(post.merge('source_code' => source)))
    end

    after { FileUtils.rm_rf(index_dir) }

    %i[json markdown plain claude].each do |format|
      it "sends every #{format} page within the default limit" do
        server = Woods::MCP::Server.build(index_dir: index_dir, response_format: format, warmup: false)
        tool = server.instance_variable_get(:@tools).fetch('lookup')
        first = tool.call(identifier: 'Post', server_context: {})
        position = first.meta.fetch(:lookup_page)
        responses = [first] + (2..position[:pages]).map do |number|
          tool.call(identifier: 'Post', page: number, answer_id: position[:answer_id], server_context: {})
        end

        expect(position[:pages]).to be > 2
        expect(responses.map(&:error?)).to all(be(false))
        expect(responses.map { |response| response.content.first[:text].length }.max)
          .to be <= Woods::MCP::LookupPages::DEFAULT_MAX_CHARS
      end
    end
  end
end
