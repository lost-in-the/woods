# frozen_string_literal: true

require 'spec_helper'
require 'timeout'
require 'woods/extracted_unit'
require 'woods/markdown/line_scan'
require 'woods/chunking/markdown_section_chunker'
require 'woods/extractors/doc_mentions'
require 'woods/extractors/doc_redaction'

# Every pattern the documentation pass adds runs against text a repository
# controls. Each input below is the shape that makes a backtracking pattern
# polynomial: a long run that almost matches, or many near-matches in a row.
RSpec.describe 'Documentation scan complexity' do
  budget_seconds = 1.0

  around do |example|
    if Regexp.respond_to?(:timeout=)
      previous = Regexp.timeout
      Regexp.timeout = budget_seconds
      begin
        Timeout.timeout(budget_seconds * 5) { example.run }
      ensure
        Regexp.timeout = previous
      end
    else
      Timeout.timeout(budget_seconds * 5) { example.run }
    end
  end

  line_inputs = {
    'unmatched backtick runs of rising length' => (1..300).map { |n| "#{'`' * n} x" }.join(' '),
    'alternating one- and two-backtick runs' => '` `` ' * 10_000,
    'a long backtick run then text' => "#{'`' * 50_000} x",
    'hashes then a bad character' => "#{'#' * 50_000}!",
    'a heading with a long space run then text' => "# a#{' ' * 50_000}x",
    'a heading closed by a long hash run' => "# a #{'#' * 50_000}",
    'a heading of hash and space pairs' => "# #{'# ' * 25_000}x",
    'a setext underline that almost matches' => "text\n#{'=' * 50_000}x",
    'a dash underline with trailing spaces then text' => "text\n#{'-' * 25_000}#{' ' * 25_000}x",
    'a fence opener with a long info string' => "```#{' a' * 25_000}",
    'tildes then a backtick' => "#{'~' * 50_000}`",
    'repeated link openers' => '](' * 25_000,
    'repeated angle link openers without a close' => '](<' * 16_000,
    'link padding then no target' => "](#{' ' * 50_000}",
    'a reference label that never closes' => "[#{'a' * 50_000}",
    'reference near-matches' => '[a]:' * 12_000,
    'a front matter key without a colon' => "---\n#{'a' * 50_000}\n---\n",
    'front matter near-keys' => "---\n#{"#{'a.' * 50}\n" * 1000}---\n"
  }

  line_inputs.each do |label, source|
    it "scans #{label} in linear time" do
      expect(Woods::Markdown::LineScan.call(source)).to be_a(Woods::Markdown::LineScan::Result)
    end
  end

  mention_inputs = {
    'a long constant chain ending lowercase' => "#{'A::' * 80}a ",
    'near-constants split by single colons' => "#{'Aa:' * 80} ",
    'a constant chain with a dangling separator' => "#{'Aa' * 100}:: ",
    'capitals inside lowercase words' => "#{'aA' * 120} ",
    'a path that almost matches' => "#{'a/' * 120}! ",
    'a path of dots' => "#{'./' * 120}a.rb ",
    'a task name with trailing colons' => "rake #{'a:' * 120} ",
    'a route with a long query' => "GET /#{'a?' * 120} "
  }

  mention_inputs.each do |label, word|
    it "tokenizes #{label} in linear time" do
      expect(Woods::Extractors::DocMentions.scan(word * 10_000)).to be_an(Array)
    end
  end

  it 'tokenizes one oversize word without scanning it' do
    expect(Woods::Extractors::DocMentions.scan("#{'A::' * 50_000}a")).to eq([])
  end

  redaction_inputs = {
    'JWT near-matches on one long line' => 'eyJ-' * 50_000,
    'JWT near-matches as many words' => 'eyJ-eyJ-eyJ.eyJ-eyJ ' * 10_000,
    'JWT near-matches on lines just under the scan cap' => "#{'eyJ-' * 255}\n" * 800,
    'base64-shaped lines just under the scan cap' => "#{'Ab+/' * 255}\n" * 800,
    'percent escapes on one long line' => '%41' * 50_000,
    'a base64-shaped run' => 'A' * 200_000,
    'connection string near-matches' => 'postgres://user:pass ' * 10_000,
    'connection strings without a host' => "#{'redis://a:b' * 300}\n" * 100,
    'private key headers that never end' => "-----BEGIN #{'A ' * 25_000}",
    'many lines of near-credentials' => "sk_test_#{'a' * 23} AKIA#{'A' * 15} key-#{'a' * 31}\n" * 10_000
  }

  redaction_inputs.each do |label, source|
    it "redacts #{label} in bounded time" do
      text, counts = Woods::Extractors::DocRedaction.new.call(source)

      expect(text.lines.size).to eq(source.lines.size)
      expect(counts).to be_a(Hash)
    end
  end

  it 'chunks a document of many tiny sections and one huge line in linear time' do
    unit = Woods::ExtractedUnit.new(type: :doc, identifier: 'docs/big.md', file_path: '/app/docs/big.md')
    unit.source_code = "#{"# h\nx\n" * 10_000}#{'y' * 500_000}\n"

    expect(Woods::Chunking::MarkdownSectionChunker.new(unit).chunk.size).to be > 10_000
  end
end
