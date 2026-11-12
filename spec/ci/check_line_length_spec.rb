# frozen_string_literal: true

require 'spec_helper'
require_relative '../../script/check_line_length'

RSpec.describe LineLengthCheck do
  let(:long) { "#{'word ' * 30}end" }

  def diff_for(path, start, *lines)
    ["diff --git a/#{path} b/#{path}", "--- a/#{path}", "+++ b/#{path}",
     "@@ -#{start},0 +#{start},#{lines.size} @@", *lines.map { |line| "+#{line}" }].join("\n")
  end

  def check(path, file_lines, added_at)
    added = added_at.map { |number| [path, number, file_lines.fetch(number - 1)] }
    described_class.violations(added, reader: ->(_) { file_lines })
  end

  describe '.added_lines' do
    it 'numbers each added line from its hunk header' do
      diff = [diff_for('docs/A.md', 7, 'one', 'two'), diff_for('ci.yml', 3, 'three')].join("\n")

      expect(described_class.added_lines(diff)).to eq(
        [['docs/A.md', 7, 'one'], ['docs/A.md', 8, 'two'], ['ci.yml', 3, 'three']]
      )
    end

    it 'keeps an added line that itself starts with plus signs' do
      expect(described_class.added_lines(diff_for('a.md', 1,
                                                  '++ not a header'))).to eq([['a.md', 1, '++ not a header']])
    end

    it 'ignores a deleted file' do
      diff = "--- a/gone.md\n+++ /dev/null\n@@ -1,1 +0,0 @@\n-old"

      expect(described_class.added_lines(diff)).to be_empty
    end
  end

  describe '.violations' do
    it 'reports an added prose line over the limit, with its position and width' do
      found = check('docs/GUIDE.md', ['short', long], [1, 2])

      expect(found.map(&:to_s)).to eq(["docs/GUIDE.md:2: #{long.length} columns (limit 120)"])
    end

    it 'accepts a line of exactly the limit' do
      expect(check('docs/GUIDE.md', ['x' * 120], [1])).to be_empty
    end

    it 'checks YAML and shell files' do
      expect(check('.github/workflows/ci.yml', [long], [1]).size).to eq(1)
      expect(check('plugin/hooks/woods-refresh.sh', [long], [1]).size).to eq(1)
    end

    it 'leaves Ruby to RuboCop and JSON unlimited' do
      expect(check('lib/woods/extractor.rb', [long], [1])).to be_empty
      expect(check('context7.json', [long], [1])).to be_empty
    end

    it 'skips generated and archived files' do
      %w[CHANGELOG.md .Codex/backlog.md spec/fixtures/a.md docs/self-analysis/a.md
         plugin/hooks/woods-input-rules.sh].each do |path|
        expect(check(path, [long], [1])).to be_empty, path
      end
    end

    it 'exempts a line that is long only because of a URL or a link' do
      url = "See https://example.com/#{'a' * 150} for details."
      link = "- [The guide](docs/#{'b' * 150}.md) explains it."

      expect(check('docs/A.md', [url, link], [1, 2])).to be_empty
    end

    it 'still reports long prose that happens to hold a link' do
      expect(check('docs/A.md', ["#{long} [guide](docs/GUIDE.md)"], [1]).size).to eq(1)
    end

    it 'exempts Markdown table rows and headings' do
      table = "| #{'cell ' * 30}|"
      heading = "## #{'Title ' * 25}"

      expect(check('docs/A.md', [table, heading], [1, 2])).to be_empty
    end

    it 'exempts a line inside a code block, and checks the prose after it' do
      lines = ['```bash', long, '```', long]

      expect(check('docs/A.md', lines, [2, 4]).map(&:number)).to eq([4])
    end

    it 'exempts a generated release-state fence, and checks the prose after it' do
      lines = ['<!-- release-state:version-banner -->', long, '<!-- release-state:end -->', long]

      expect(check('README.md', lines, [2, 4]).map(&:number)).to eq([4])
    end

    it 'does not exempt a table-shaped line in YAML' do
      expect(check('ci.yml', ["| #{'cell ' * 30}|"], [1]).size).to eq(1)
    end
  end
end
