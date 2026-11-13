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

    # A page, asked for as its predecessor's closing line says to: with the
    # answer_id the first page gave.
    def page_of(number, format = :markdown, **arguments)
      return lookup(format, **arguments) if number == 1

      answer = Woods::MCP::LookupPages.answer_id(text(lookup(format, max_chars: 2_000_000)),
                                                 arguments.fetch(:max_chars))
      lookup(format, **arguments, page: number, answer_id: answer)
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
      bodies = (1..pages).map { |number| body(page_of(number, max_chars: 3000)) }

      expect(pages).to be > 3
      expect(first.error?).to be(false)
      expect(text(first)).to start_with("[lookup page 1 of #{pages}: characters 1-")
      expect(text(first)).to include('Call lookup again with the same arguments, page: 2 and ' \
                                     "answer_id: \"#{first.meta.dig(:lookup_page, :answer_id)}\" for the next part.")
      expect(bodies.join).to eq(whole)
    end

    it 'says the last page is the last' do
      pages = lookup(max_chars: 3000).meta.dig(:lookup_page, :pages)
      last = page_of(pages, max_chars: 3000)

      expect(text(last)).to include('This is the last page.')
      expect(last.meta[:lookup_page]).to include(page: pages, next_page: nil)
    end

    it 'refuses a page that does not exist, naming how many there are' do
      pages = lookup(max_chars: 3000).meta.dig(:lookup_page, :pages)
      response = page_of(pages + 1, max_chars: 3000)

      expect(response.error?).to be(true)
      expect(text(response)).to eq("lookup of Post has #{pages} pages; page #{pages + 1} does not exist.")
      expect(response.meta).to include(error_code: :invalid_params, pages: pages)
    end

    it 'refuses page 2 of a unit that fits in one answer' do
      response = page_of(2, max_chars: 2_000_000)

      expect(response.error?).to be(true)
      expect(text(response)).to eq('lookup of Post has 1 page; page 2 does not exist.')
    end

    describe 'when the unit changes between two pages' do
      def publish_changed_unit
        path = Dir[File.join(index_dir, 'models', 'Post*.json')].first
        unit = JSON.parse(File.read(path, encoding: 'UTF-8'))
        # Metadata only, and ahead of the first page boundary: the source,
        # and so its SHA-256, is the same.
        unit['metadata'] = unit.fetch('metadata').merge('table_name' => 'articles_renamed_since_page_one')
        File.write(path, JSON.generate(unit))
      end

      def request(server, arguments)
        message = { jsonrpc: '2.0', id: 1, method: 'tools/call', params: { name: 'lookup', arguments: arguments } }
        JSON.parse(server.handle_json(JSON.generate(message))).fetch('result')
      end

      it 'refuses the next page over the wire, and says to start again' do
        server = Woods::MCP::Server.build(index_dir: index_dir, response_format: :markdown, warmup: false)
        first = request(server, 'identifier' => 'Post', 'max_chars' => 3000)
        answer = first.dig('_meta', 'lookup_page', 'answer_id')
        publish_changed_unit
        server.instance_variable_get(:@tools).fetch('reload').call(server_context: {})

        second = request(server, 'identifier' => 'Post', 'max_chars' => 3000, 'page' => 2, 'answer_id' => answer)

        expect(first['isError']).to be(false)
        expect(second['isError']).to be(true)
        expect(second.dig('_meta', 'error_code')).to eq('stale_index')
        expect(second.dig('content', 0, 'text'))
          .to eq("Post changed since the page that gave answer_id #{answer} (the index was republished, or " \
                 'max_chars differs). The pages already read belong to the earlier answer; start again from page 1.')
        expect(second.dig('_meta', 'answer_id')).not_to eq(answer)
      end

      it 'serves the next page when nothing changed' do
        first = lookup(max_chars: 3000)
        second = lookup(max_chars: 3000, page: 2, answer_id: first.meta.dig(:lookup_page, :answer_id))

        expect(second.error?).to be(false)
        expect(second.meta[:lookup_page]).to include(page: 2, answer_id: first.meta.dig(:lookup_page, :answer_id))
      end

      it 'refuses a later page cut at another page size' do
        first = lookup(max_chars: 3000)
        response = lookup(max_chars: 5000, page: 2, answer_id: first.meta.dig(:lookup_page, :answer_id))

        expect(response.error?).to be(true)
        expect(response.meta).to include(error_code: :stale_index)
      end

      it 'refuses a later page that names no answer' do
        response = lookup(max_chars: 3000, page: 2)

        expect(response.error?).to be(true)
        expect(response.meta).to include(error_code: :invalid_params, argument: 'answer_id')
        expect(text(response)).to include('needs the answer_id the previous page gave')
      end
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
      expect(text(response)).to include('page, max_chars and answer_id apply only to full evidence')
    end

    it 'refuses budget and query on a full lookup and says how to use them' do
      [{ budget: 3000 }, { query: 'refund' }].each do |arguments|
        response = lookup(**arguments)

        expect(response.error?).to be(true)
        expect(text(response)).to include('Add evidence: "compact" (or "outline") to use them')
                              .and include('page a full lookup with max_chars and page')
      end
    end

    describe 'in the JSON format' do
      def json_page(number)
        JSON.parse(text(page_of(number, :json, max_chars: 3000)))
      end

      let(:whole) { JSON.parse(text(lookup(:json, max_chars: 2_000_000))) }
      let(:pages) { lookup(:json, max_chars: 3000).meta.dig(:lookup_page, :pages) }

      it 'answers every page as JSON that parses on its own and holds part of the unit' do
        (1..pages).each do |number|
          parsed = json_page(number)
          expect(parsed.keys).to eq(%w[lookup_page unit])
          expect(parsed.fetch('lookup_page')).to include('page' => number, 'pages' => pages)
          expect(parsed.fetch('unit')).to be_a(Hash).and(satisfy { |unit| !unit.empty? })
        end
      end

      it 'gives the unit back when the pages are merged in order' do
        units = (1..pages).map { |number| json_page(number).fetch('unit') }

        expect(pages).to be > 3
        expect(described_class.merge_json_units(units)).to eq(whole)
      end

      it 'cuts long source at line ends and says which lines a page holds' do
        sources = (1..pages).filter_map do |number|
          parsed = json_page(number)
          part = parsed.dig('lookup_page', 'parts').find { |entry| entry['key'] == 'source_code' }
          [parsed.dig('unit', 'source_code'), part.fetch('lines')] if part
        end

        expect(sources.size).to be > 2
        expect(sources.map(&:first).join).to eq(whole.fetch('source_code'))
        expect(sources.map(&:first)[0...-1]).to all(end_with("\n"))
        expect(sources.first.last.first).to eq(1)
        sources.each_cons(2) { |(_, before), (_, after)| expect(after.first).to eq(before.last + 1) }
        sources.each { |source, (first, last)| expect(source.lines.size).to eq(last - first + 1) }
      end

      it 'keeps each page near the limit' do
        (1..pages).each { |number| expect(text(page_of(number, :json, max_chars: 3000)).length).to be <= 3600 }
      end

      it 'says in each page how to get the next and how to merge' do
        first = json_page(1).fetch('lookup_page')
        last = json_page(pages).fetch('lookup_page')

        expect(first.fetch('how_to_continue'))
          .to eq("Call lookup again with the same arguments, page: 2 and answer_id: \"#{first.fetch('answer_id')}\". " \
                 'Merge the unit objects of all pages in order: objects merge by key, and strings and lists ' \
                 'under the same key are joined.')
        expect(last.fetch('how_to_continue')).to start_with('This is the last page.')
        expect(last.fetch('next_page')).to be_nil
      end

      it 'gives the same page as structured data' do
        response = lookup(:json, max_chars: 3000)

        expect(JSON.parse(JSON.generate(response.structured_content.fetch(:data)))).to eq(JSON.parse(text(response)))
      end

      it 'refuses a later page when the unit changed, as the other formats do' do
        first = lookup(:json, max_chars: 3000)
        response = lookup(:json, max_chars: 5000, page: 2, answer_id: first.meta.dig(:lookup_page, :answer_id))

        expect(response.error?).to be(true)
        expect(response.meta).to include(error_code: :stale_index)
      end

      it 'answers a unit that fits as its own JSON document, with no envelope' do
        expect(whole).to include('identifier' => 'Post')
        expect(whole).not_to have_key('lookup_page')
      end
    end

    describe '.json_pages' do
      def roundtrip(unit, max_chars)
        pages = described_class.json_pages(unit, max_chars)
        [pages, described_class.merge_json_units(pages.map { |page| page.fetch('unit') })]
      end

      it 'splits a long list between items and says which items a page holds' do
        unit = { 'identifier' => 'Order',
                 'metadata' => { 'callbacks' => Array.new(60) { |index| { 'filter' => "callback_#{index}" } } } }

        pages, merged = roundtrip(unit, 1500)
        spans = pages.flat_map { |page| page.fetch('parts') }.select { |part| part['key'] == 'metadata.callbacks' }

        expect(merged).to eq(unit)
        expect(spans.size).to be > 1
        expect(spans.first.fetch('items').first).to eq(0)
        expect(spans.last.fetch('items').last).to eq(59)
        spans.each_cons(2) { |before, after| expect(after['items'].first).to eq(before['items'].last + 1) }
      end

      it 'keeps a value it cannot cut whole on a page of its own' do
        unit = { 'identifier' => 'Order', 'blob' => 'x' * 5000, 'count' => 3, 'flag' => false, 'nothing' => nil }

        pages, merged = roundtrip(unit, 1500)

        expect(merged).to eq(unit)
        expect(pages.size).to be > 1
      end

      it 'answers one page for a small unit' do
        pages, merged = roundtrip({ 'identifier' => 'Order', 'metadata' => {} }, 1500)

        expect(pages.size).to eq(1)
        expect(merged).to eq('identifier' => 'Order', 'metadata' => {})
      end
    end

    %i[plain claude].each do |format|
      it "pages the #{format} rendering without losing any of it" do
        whole = text(lookup(format, max_chars: 2_000_000))
        pages = lookup(format, max_chars: 3000).meta.dig(:lookup_page, :pages)
        bodies = (1..pages).map { |number| body(page_of(number, format, max_chars: 3000)) }

        expect(bodies.join).to eq(whole)
      end
    end
  end
end
