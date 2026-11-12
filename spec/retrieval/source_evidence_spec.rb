# frozen_string_literal: true

require 'spec_helper'
require 'woods/retrieval/source_evidence'

RSpec.describe Woods::Retrieval::SourceEvidence do
  def unit(source, **extra)
    { 'identifier' => 'Billing::Invoice', 'type' => 'model', 'file_path' => 'app/models/billing/invoice.rb',
      'source_code' => source }.merge(extra.transform_keys(&:to_s))
  end

  def render(data, query: 'refund', mode: 'compact', budget: 400, generation: nil, parser: Woods::Ast::Parser.new)
    described_class.new(unit: data, query: query, generation: generation, parser: parser)
                   .render(mode: mode, budget: budget, counter: ->(text) { (text.length / 4.0).ceil })
  end

  it 'retains a complete relevant method after a long unrelated prefix within the budget' do
    prefix = (1..80).map { |i| "def unrelated_#{i}; #{'nil; ' * 25}end\n" }.join
    source = "class Billing::Invoice\n#{prefix}def refund(payment)\n payment.reverse!\nend\nend\n"
    result = render(unit(source))
    expect(result.text).to include("def refund(payment)\n payment.reverse!\nend")
    expect(result.text.length).to be <= 1600
    expect(result.provenance[:omitted_spans]).to be_positive
    expect(result.text).to include('evidence: full')
  end

  [true, false].each do |prism|
    it "preserves exact Unicode byte coordinates on shared lines with #{prism ? 'Prism' : 'parser'}" do
      parser = Woods::Ast::Parser.new
      allow(parser).to receive(:prism_available?).and_return(prism)
      source = 'é = 1; class First; def refund; :wrong; end; end; class Billing::Invoice; def café; :ok; end; end'
      result = render(unit(source), query: 'café', parser: parser)
      span = result.provenance[:spans].find { |entry| entry[:name] == 'café' }
      expect(source.byteslice(span[:start_byte]...span[:end_byte])).to eq('def café; :ok; end')
      expect(span[:lexical_owner]).to eq('Billing::Invoice')
      expect(span[:sha256]).to eq(Digest::SHA256.hexdigest('def café; :ok; end'))
      expect(result.provenance[:physical_location]).to be_nil
    end

    it "never presents an unfinished heredoc as a complete method with #{prism ? 'Prism' : 'parser'}" do
      parser = Woods::Ast::Parser.new
      allow(parser).to receive(:prism_available?).and_return(prism)
      ["class Invoice\n  def refund = <<~SQL\n    SELECT 'refund'\n  SQL\nend\n",
       "class Invoice\n  def refund; <<~SQL; end\n    SELECT 'refund'\n  SQL\nend\n"].each do |source|
        result = render(unit(source), parser: parser, budget: 800)
        expect(result.text).to include(source)
        expect(result.provenance[:spans].map { |span| span[:kind] }).to eq(['whole_source_fallback'])
        tiny = render(unit(source * 100), parser: parser, budget: 200)
        expect(tiny.provenance[:spans]).to be_empty
      end
    end

    it "resets singleton context inside a fresh class with #{prism ? 'Prism' : 'parser'}" do
      parser = Woods::Ast::Parser.new
      allow(parser).to receive(:prism_available?).and_return(prism)
      source = 'class Invoice; class << self; class Nested; def refund; :ok; end; end; end; end'
      result = render(unit(source), parser: parser)
      expect(result.provenance[:spans].first[:kind]).to eq('instance_method')
    end

    it "retains a declared receiver without inferring runtime ownership with #{prism ? 'Prism' : 'parser'}" do
      parser = Woods::Ast::Parser.new
      allow(parser).to receive(:prism_available?).and_return(prism)
      result = render(unit('class Invoice; def Other.refund; :ok; end; end'), parser: parser)
      expect(result.provenance[:spans].first).to include(lexical_owner: 'Invoice', receiver: 'Other')
    end

    it "preserves original CRLF bytes after Unicode with #{prism ? 'Prism' : 'parser'}" do
      parser = Woods::Ast::Parser.new
      allow(parser).to receive(:prism_available?).and_return(prism)
      method = "def café\r\n    :ok\r\n  end"
      source = "é = 1\r\nclass Invoice\r\n  #{method}\r\nend\r\n"
      result = render(unit(source), query: 'café', parser: parser)
      span = result.provenance[:spans].find { |entry| entry[:name] == 'café' }
      expect(source.byteslice(span[:start_byte]...span[:end_byte])).to eq(method)
      expect(span).to include(start_line: 3, end_line: 5, sha256: Digest::SHA256.hexdigest(method))
    end
  end

  it 'keeps nested blocks and definitions inside their complete containing method' do
    source = "module Billing\nclass Invoice\ndef refund\n[1].each do |n|\n def nested; :ok; end\nend\nend\nend\nend"
    result = render(unit(source))
    expect(result.provenance[:spans].map { |entry| entry[:name] }).to eq(['refund'])
    expect(result.text).to include("def nested; :ok; end\nend\nend")
    expect(result.provenance[:spans].first[:lexical_owner]).to eq('Billing::Invoice')
  end

  it 'preserves commented concern evidence without relabeling it as physical source' do
    source = <<~SOURCE
      class Billing::Invoice
      # │ Included from: Refundable                                            │
      # └─────────────────────────────────────────────────────────────────────┘
        # module Refundable
        #   def refund; payment.reverse!; end
        # end
      # ─────────────────────────── End Refundable ───────────────────────────
      def unrelated; end
      end
    SOURCE
    result = render(unit(source, metadata: { 'inlined_concerns' => ['Refundable'] }))
    span = result.provenance[:spans].find { |entry| entry[:kind] == 'inlined_concern_display' }
    expect(span[:lexical_owner]).to eq('Refundable')
    expect(result.text).to include('#   def refund; payment.reverse!; end')
    expect(result.provenance[:coordinate_system]).to eq('published_unit')
    expect(result.provenance[:physical_location]).to be_nil
  end

  describe 'a concern that matches more of the query than the unit\'s own method' do
    let(:concern_lines) do
      %w[login captcha session token browser].map { |word| "  #   def #{word}_check; #{word}; end" }.join("\n")
    end
    let(:source) do
      <<~SOURCE
        class SessionsController
        # │ Included from: Authentication                                        │
          # module Authentication
        #{concern_lines}
          # end
        # ─────────────────────────── End Authentication ───────────────────────────
        def create
          login(params[:captcha])
        end
        def destroy; reset_session; end
        end
      SOURCE
    end
    let(:data) { unit(source, metadata: { 'inlined_concerns' => ['Authentication'] }) }

    it 'never spends the budget on the concern while the matching method is left out' do
      (40..600).step(10) do |budget|
        text = render(data, query: 'login captcha session token', budget: budget).text
        next unless text.include?('module Authentication')

        expect(text).to include("def create\n  login(params[:captcha])\nend"), "budget #{budget}"
      end
    end

    it 'still includes the matching concern when the budget holds both' do
      both = render(data, query: 'login captcha session token', budget: 600)

      expect(both.text).to include('login(params[:captcha])').and include('#   def captcha_check; captcha; end')
    end

    it 'still selects a concern that is the only match' do
      text = render(data, query: 'browser', budget: 600).text

      expect(text).to include('#   def browser_check; browser; end')
    end
  end

  it 'finds a namespaced concern display block by the full name the header carries' do
    source = <<~SOURCE
      class Billing::Invoice
      # │ Included from: Canopy::Refundable                                    │
      # └─────────────────────────────────────────────────────────────────────┘
        # module Canopy::Refundable
        #   def refund; payment.reverse!; end
        # end
      # ─────────────────────────── End Canopy::Refundable ───────────────────────────
      end
    SOURCE
    result = render(unit(source, metadata: { 'inlined_concerns' => ['Canopy::Refundable'] }))
    span = result.provenance[:spans].find { |entry| entry[:kind] == 'inlined_concern_display' }
    expect(span).to include(name: 'Canopy::Refundable', lexical_owner: 'Canopy::Refundable')
  end

  it 'provides an outline without pretending to infer signatures or inherited definitions' do
    data = unit('class Billing::Invoice < Parent; def refund(payment); payment.reverse!; end; end',
                metadata: { 'callbacks' => [{ 'method' => 'inherited_refund', 'defined_in' => 'Parent' }] })
    result = render(data, mode: 'outline')
    expect(result.text).to include('instance_method Billing::Invoice refund')
    expect(result.text).not_to include('payment.reverse!')
    expect(result.provenance[:spans].map { |entry| entry[:name] }).to eq(['refund'])
    expect(result.provenance[:runtime_fields]).to include('callbacks')
  end

  it 'reports absent generation rather than borrowing current index state for old semantic artifacts' do
    result = render(unit('def refund; end'))
    expect(result.provenance).to include(generation: nil, generation_status: 'unavailable')
    expect(result.text).to include('Generation: unavailable')
    expect(render(unit('def refund; end'), generation: 19).provenance).to include(generation: 19)
  end

  it 'never returns a misleading partial method when no complete span fits' do
    result = render(unit("def refund; #{'nil; ' * 2000}end"))
    expect(result.text).not_to include('def refund')
    expect(result.provenance[:spans]).to be_empty
    expect(result.provenance[:omitted_spans]).to eq(1)
    expect(result.text).to include('Omitted: 1 source spans')
  end

  it 'returns no text if even the minimum provenance notice cannot fit' do
    result = render(unit('def refund; end'), budget: 1)
    expect(result.text).to eq('')
    expect(result.provenance[:spans]).to be_empty
  end

  it 'treats non-Ruby source as one whole published span instead of inventing boundaries' do
    source = '<section>Refund this invoice</section>'
    result = render(unit(source))
    expect(result.text).to include(source)
    expect(result.provenance[:spans].first[:kind]).to eq('unparsed_source')
  end
end
