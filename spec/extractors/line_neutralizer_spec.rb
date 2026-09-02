# frozen_string_literal: true

require 'spec_helper'
require 'woods/extractors/line_neutralizer'

RSpec.describe Woods::Extractors::LineNeutralizer do
  describe '.strip_line_comment' do
    it 'removes a trailing comment' do
      expect(described_class.strip_line_comment("module Api # rename at the end\n")).to eq("module Api \n")
    end

    it 'keeps a `#` that lives inside a string literal' do
      line = %(link_to "Tag #ruby", Article.recent\n)

      expect(described_class.strip_line_comment(line)).to eq(line)
    end

    it 'honors escaped quotes inside a literal' do
      line = %(a = "it\\"s # fine" # cut\n)

      expect(described_class.strip_line_comment(line)).to eq(%(a = "it\\"s # fine" \n))
    end

    it 'leaves a comment-free line untouched' do
      expect(described_class.strip_line_comment("x = 1\n")).to eq("x = 1\n")
    end
  end

  describe '.neutralize_line' do
    it 'blanks the body of a string literal so its words cannot read as code' do
      expect(described_class.neutralize_line(%(title { "things to do" }\n))).to eq(%(title { "            " }\n))
    end

    it 'blanks string bodies and strips the trailing comment together' do
      expect(described_class.neutralize_line(%(x = 'do it' # for now\n))).to eq(%(x = '     ' \n))
    end

    it 'preserves code outside literals' do
      expect(described_class.neutralize_line("items.each do |item|\n")).to eq("items.each do |item|\n")
    end
  end

  describe '.strip_comments' do
    it 'strips comments from every line, preserving line count' do
      source = "a = 1 # one\n# whole line\nb = 2\n"

      expect(described_class.strip_comments(source)).to eq("a = 1 \n\nb = 2\n")
    end
  end

  describe '.neutralize_lines' do
    it 'returns one neutralized line per input line' do
      source = "a = 1\nb = 2\n"

      expect(described_class.neutralize_lines(source).size).to eq(2)
    end

    it 'blanks heredoc bodies so their prose cannot read as code' do
      source = <<~RUBY
        sql = <<~SQL
          end of the road
        SQL
        ImportantService.call
      RUBY

      expect(described_class.neutralize_lines(source)).to eq(
        ["sql = <<~SQL\n", "\n", "\n", "ImportantService.call\n"]
      )
    end

    it 'blanks a quoted-identifier heredoc body' do
      source = "raw = <<~'RAW'\n  do it\nRAW\nz = 1\n"

      expect(described_class.neutralize_lines(source)).to eq(["raw = <<~'RAW'\n", "\n", "\n", "z = 1\n"])
    end

    it 'does not treat the `<<` shift operator as a heredoc' do
      source = "list << Item\nnext_line = 1\n"

      expect(described_class.neutralize_lines(source)).to eq(["list << Item\n", "next_line = 1\n"])
    end
  end
end
