# frozen_string_literal: true

require 'spec_helper'
require 'fileutils'
require 'json'
require 'tmpdir'
require 'woods/mcp/server'

RSpec.describe Woods::MCP::LookupPages do
  describe '.split' do
    it 'cuts at line ends and loses nothing' do
      text = Array.new(40) { |index| "line #{index} #{'x' * 30}\n" }.join

      pieces = described_class.split(text, 200)

      expect(pieces.join).to eq(text)
      expect(pieces.size).to be > 1
      expect(pieces.map(&:length)).to all(be <= 200)
      expect(pieces[0...-1]).to all(end_with("\n"))
    end

    it 'cuts a single line longer than a page' do
      text = "#{'a' * 450}\nshort\n"

      pieces = described_class.split(text, 200)

      expect(pieces.join).to eq(text)
      expect(pieces.map(&:length)).to all(be <= 200)
    end

    it 'keeps multibyte text whole' do
      text = "café — 日本語\n" * 30

      expect(described_class.split(text, 50).join).to eq(text)
    end

    it 'answers one piece for a short or empty text' do
      expect(described_class.split("short\n", 200)).to eq(["short\n"])
      expect(described_class.split('', 200)).to eq([''])
    end
  end

  describe '.limit' do
    it 'defaults, and takes the environment or the call over the default' do
      expect(described_class.limit(nil, env: {})).to eq(40_000)
      expect(described_class.limit(nil, env: { 'WOODS_MCP_LOOKUP_MAX_CHARS' => '9000' })).to eq(9000)
      expect(described_class.limit(5000, env: { 'WOODS_MCP_LOOKUP_MAX_CHARS' => '9000' })).to eq(5000)
    end

    it 'turns paging off for 0 and ignores a value that is not a number' do
      expect(described_class.limit(nil, env: { 'WOODS_MCP_LOOKUP_MAX_CHARS' => '0' })).to be_nil
      expect(described_class.limit(nil, env: { 'WOODS_MCP_LOOKUP_MAX_CHARS' => 'lots' })).to eq(40_000)
    end
  end

  describe '.page' do
    let(:text) { Array.new(30) { |index| "row #{index}\n" }.join }

    it 'reports where each page sits and what comes next' do
      first = described_class.page(text, max_chars: 100, number: 1)
      last = described_class.page(text, max_chars: 100, number: first.pages)

      expect(first.to_h).to include(page: 1, first_char: 1, total_chars: text.length, next_page: 2)
      expect(last.to_h).to include(page: first.pages, last_char: text.length, next_page: nil)
    end

    it 'has no page past the last or before the first' do
      count = described_class.page(text, max_chars: 100, number: 1).pages

      expect(described_class.page(text, max_chars: 100, number: count + 1)).to be_nil
      expect(described_class.page(text, max_chars: 100, number: 0)).to be_nil
    end
  end

  describe 'the lookup tool' do
    let(:index_dir) { Dir.mktmpdir('woods-lookup-pages') }
    let(:source) { Array.new(400) { |index| "  def method_#{index}; #{index}; end\n" }.join }

    before do
      FileUtils.cp_r(File.join(File.expand_path('../fixtures/woods', __dir__), '.'), index_dir)
      path = Dir[File.join(index_dir, 'models', 'Post*.json')].first
      unit = JSON.parse(File.read(path, encoding: 'UTF-8'))
      File.write(path, JSON.generate(unit.merge('source_code' => "class Post\n#{source}end\n")))
    end

    after { FileUtils.rm_rf(index_dir) }

    def lookup(format = :markdown, **arguments)
      server = Woods::MCP::Server.build(index_dir: index_dir, response_format: format, warmup: false)
      server.instance_variable_get(:@tools).fetch('lookup').call(identifier: 'Post', **arguments, server_context: {})
    end

    def text(response)
      response.content.first[:text]
    end

    # The page's own characters: what lies between the position lines, cut
    # to the length the page reports (a page that ends inside a line gets a
    # line break before the closing line).
    def body(response)
      position = response.meta.fetch(:lookup_page)
      text(response).lines[1...-1].join[0, position[:last_char] - position[:first_char] + 1]
    end

    it 'answers a unit that fits in one answer whole, with no page lines' do
      response = lookup(max_chars: 2_000_000)

      expect(text(response)).not_to include('lookup page')
      expect(text(response)).to include('def method_399')
    end

    it 'answers a long unit one page at a time, and the pages make up the whole answer' do
      whole = text(lookup(max_chars: 2_000_000))
      first = lookup(max_chars: 3000)
      pages = first.meta.dig(:lookup_page, :pages)
      bodies = (1..pages).map { |number| body(lookup(max_chars: 3000, page: number)) }

      expect(pages).to be > 3
      expect(first.error?).to be(false)
      expect(text(first)).to start_with("[lookup page 1 of #{pages}: characters 1-")
      expect(text(first)).to include('Call lookup again with the same arguments and page: 2 for the next part.')
      expect(bodies.join).to eq(whole)
    end

    it 'says the last page is the last' do
      pages = lookup(max_chars: 3000).meta.dig(:lookup_page, :pages)
      last = lookup(max_chars: 3000, page: pages)

      expect(text(last)).to include('This is the last page.')
      expect(last.meta[:lookup_page]).to include(page: pages, next_page: nil)
    end

    it 'refuses a page that does not exist, naming how many there are' do
      pages = lookup(max_chars: 3000).meta.dig(:lookup_page, :pages)
      response = lookup(max_chars: 3000, page: pages + 1)

      expect(response.error?).to be(true)
      expect(text(response)).to eq("lookup of Post has #{pages} pages; page #{pages + 1} does not exist.")
      expect(response.meta).to include(error_code: :invalid_params, pages: pages)
    end

    it 'refuses page 2 of a unit that fits in one answer' do
      response = lookup(max_chars: 2_000_000, page: 2)

      expect(response.error?).to be(true)
      expect(text(response)).to eq('lookup of Post has 1 page; page 2 does not exist.')
    end

    it 'pages by default at the configured limit' do
      stub_const('ENV', ENV.to_h.merge('WOODS_MCP_LOOKUP_MAX_CHARS' => '4000'))

      expect(lookup.meta.dig(:lookup_page, :last_char)).to be <= 4000
    end

    it 'does not page when the configured limit is 0' do
      stub_const('ENV', ENV.to_h.merge('WOODS_MCP_LOOKUP_MAX_CHARS' => '0'))

      expect(text(lookup)).not_to include('lookup page')
    end

    it 'pages what sections and include_source leave' do
      response = lookup(max_chars: 3000, include_source: false)

      expect(text(response)).not_to include('lookup page')
      expect(text(response)).not_to include('def method_1;')
    end

    it 'leaves compact evidence to its own budget and refuses page with it' do
      response = lookup(evidence: 'compact', page: 2)

      expect(response.error?).to be(true)
      expect(text(response)).to include('page and max_chars apply only to full evidence')
    end

    %i[json plain claude].each do |format|
      it "pages the #{format} rendering without losing any of it" do
        whole = text(lookup(format, max_chars: 2_000_000))
        pages = lookup(format, max_chars: 3000).meta.dig(:lookup_page, :pages)
        bodies = (1..pages).map { |number| body(lookup(format, max_chars: 3000, page: number)) }

        expect(bodies.join).to eq(whole)
      end
    end
  end
end
