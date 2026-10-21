# frozen_string_literal: true

require 'spec_helper'
require 'timeout'
require 'woods/extracted_unit'
require 'woods/ruby_analyzer/trace_enricher'
require 'woods/chunking/semantic_chunker'
require 'woods/retrieval/query_classifier'
require 'woods/retrieval/source_evidence'

# Ruby 3.2+ memoizes backtracking, which hides polynomial patterns; the
# timeout still catches them, and Ruby < 3.2 runs under a wall-clock budget.
RSpec.describe 'scan hygiene: regex complexity' do
  def within_budget(&block)
    if Regexp.respond_to?(:timeout=)
      previous = Regexp.timeout
      Regexp.timeout = 1.0
      begin
        block.call
      ensure
        Regexp.timeout = previous
      end
    else
      Timeout.timeout(5, &block)
    end
  end

  describe Woods::RubyAnalyzer::TraceEnricher do
    def parse(identifier)
      described_class.send(:parse_identifier, identifier)
    end

    it 'splits an identifier at its first separator exactly as the anchored pattern did' do
      legacy = lambda do |identifier|
        match = /\A(.+?)([#.])(.+)\z/.match(identifier)
        match && [match[1], match[3], match[2] == '#' ? 'instance' : 'singleton']
      end
      identifiers = ['Widget#ship', 'Widget.build', 'Ledger::Entry#post!', 'Widget.build#later', 'Widget#a.b',
                     '#ship', '.build', '##ship', 'Widget#', 'Widget.', 'Widget', '', "Widget#ship\n",
                     "Widget\n#ship", "Wid\nget#ship", 'Wídget#shíp', '#', '..', 'a.b.c', :'Widget#ship', nil]

      identifiers.each { |identifier| expect(parse(identifier)).to eq(legacy.call(identifier)), identifier.inspect }
    end

    it 'rejects separator runs before a line break in linear time' do
      within_budget do
        expect(parse("Widget#{'#' * 50_000}\n")).to be_nil
        expect(parse("Widget#{'.' * 50_000}\nship")).to be_nil
        expect(parse("#{'Widget#' * 10_000}\n")).to be_nil
        expect(parse('W' * 50_000)).to be_nil
        expect(parse("Widget#{'#' * 50_000}")).to eq(['Widget', '#' * 49_999, 'instance'])
      end
    end
  end

  describe Woods::Chunking::LineDepthTracking do
    subject(:tracker) { Class.new { include Woods::Chunking::LineDepthTracking }.new }

    def opener?(line)
      tracker.send(:block_opener?, line)
    end

    it 'classifies do-block lines exactly as the backtracking pattern did' do
      legacy = /\bdo\s*(?:\|[^|]*\|)?\s*(?:#.*)?\z/
      lines = ['items.each do', 'items.each do |item|', 'items.each do |item, (a, b)| # note', 'run do # why',
               'run do#why', 'run do |a| |b|', 'run do |a', 'run do   |a|   ', 'todo', 'do', 'do |', 'do ||',
               'run do x', 'run do |a| x', 'undo do', 'do do do', "run do\t|a|\t#", 'x # do', 'x # do # do',
               'run do |a| # |b|', 'run do |é| # ü']

      lines.each do |line|
        expect(line.match?(described_class::DO_BLOCK_PATTERN)).to eq(line.match?(legacy)), line.inspect
      end
    end

    it 'rejects do-block near-matches in linear time' do
      within_budget do
        expect(opener?("run do#{' ' * 50_000}x")).to be(false)
        expect(opener?("run do#{" \t" * 50_000}|a")).to be(false)
        expect(opener?("#{'do ' * 50_000}x")).to be(false)
        expect(opener?("#{'do |' * 50_000}x")).to be(false)
        expect(opener?("#{'do |a| ' * 10_000}x")).to be(false)
        expect(opener?("run do |#{'a' * 50_000}")).to be(false)
        expect(opener?("#{'do ' * 50_000}do")).to be(true)
      end
    end
  end

  describe Woods::Retrieval::QueryClassifier do
    subject(:classifier) { described_class.new }

    # rubocop:disable Layout/LineLength
    legacy_framework = /\b(how does rails|what does rails|rails .+ work|work.+\brails\b|in rails\b|activerecord|actioncontroller|activejob|actionmailer|actioncable|actiontext|activestorage|solid_queue|solid_cache|solid_cable|kamal|propshaft|importmap|hotwire|turbo|stimulus|zeitwerk)\b/i
    legacy_schedule = /\b(schedule[dr]?|recurring|cron|periodic|every\s+\d|daily|hourly|weekly|solid.?queue.*recur|sidekiq.?cron|whenever)\b/i
    # rubocop:enable Layout/LineLength

    it 'recognizes framework phrasing exactly as the backtracking alternatives did' do
      pattern = described_class::INTENT_PATTERNS.fetch(:framework)
      queries = ['how do rails callbacks work', 'rails does work', 'rails  work', 'rails work', 'work in rails',
                 'workrails', 'work rails', 'worker rails', 'rails x working', 'RAILS things WORK?',
                 "rails things\nwork", "trails callbacks work\nrails callbacks work", 'work, then rails',
                 'homework on rails', 'rails rails work work', 'work x railsy', 'x rails y work z',
                 'how does rails boot', 'what is zeitwerk', 'in rails', 'turbo frames', 'a plain question', '']

      queries.each { |query| expect(query.match?(pattern)).to eq(query.match?(legacy_framework)), query.inspect }
    end

    it 'recognizes scheduled-job phrasing exactly as the backtracking alternative did' do
      pattern = described_class::TARGET_PATTERNS.fetch(:scheduled_job)
      queries = ['solid queue recurring', 'solidqueue recur', 'solid_queue tasks that recur', 'solid queue',
                 'solid  queue recur', "solid queue\nrecur", 'unsolid queue recur', 'solid queue recurx',
                 'SOLID-QUEUE now RECUR', 'solid queue solid queue recur', 'recur solid queue', 'solidqueuerecur',
                 'every 5 minutes', 'the scheduler', 'sidekiq cron', 'a plain question', '']

      queries.each { |query| expect(query.match?(pattern)).to eq(query.match?(legacy_schedule)), query.inspect }
    end

    it 'classifies repeated leads without a tail in linear time' do
      schedule = described_class::TARGET_PATTERNS.fetch(:scheduled_job)
      within_budget do
        expect(classifier.classify('rails ' * 50_000).intent).to eq(:understand)
        expect(classifier.classify('work ' * 50_000).intent).to eq(:understand)
        expect(classifier.classify("#{'rails x wor ' * 10_000}k").intent).to eq(:understand)
        expect(classifier.classify("rails \n" * 50_000).intent).to eq(:understand)
        expect(classifier.classify("#{'rails ' * 50_000}x work").intent).to eq(:framework)
        expect(classifier.classify('solidqueue ' * 50_000).target_type).to be_nil
        expect(schedule.match?('solid queue ' * 50_000)).to be(false)
        expect(schedule.match?("#{'solidqueue recu ' * 10_000}r")).to be(false)
        expect(schedule.match?("#{'solid queue ' * 50_000}recur")).to be(true)
      end
    end
  end

  describe Woods::Retrieval::SourceEvidence do
    def concern_spans(source, names)
      unit = { 'identifier' => 'Widget', 'type' => 'model', 'source_code' => source,
               'metadata' => { 'inlined_concerns' => names } }
      described_class.new(unit: unit).send(:concern_spans)
    end

    it 'finds no display block among unterminated headers in linear time' do
      within_budget do
        expect(concern_spans("# │ Included from: Shippable │\n" * 50_000, ['Shippable'])).to eq([])
        expect(concern_spans("# │ Included from: Shippable#{' ' * 50_000}\n", ['Shippable'])).to eq([])
        expect(concern_spans("# │ Included from: Shippable │\n#{"# #{'─' * 20} End Shippabl ─\n" * 10_000}",
                             ['Shippable'])).to eq([])
        expect(concern_spans("# │ Included from: Shippable │\n# #{'─' * 50_000} End", ['Shippable'])).to eq([])
      end
    end

    it 'closes the first header at the nearest footer after repeated headers' do
      headers = "# │ Included from: Shippable │\n" * 50_000
      span = within_budget { concern_spans("#{headers}# ─ End Shippable ─\n", ['Shippable']).first }

      expect([span.start_byte, span.start_line, span.end_line]).to eq([0, 1, 50_001])
      expect(span.end_byte).to eq(headers.bytesize + '# ─ End Shippable ─'.bytesize)
    end
  end
end
