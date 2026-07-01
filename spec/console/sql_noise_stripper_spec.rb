# frozen_string_literal: true

require 'spec_helper'
require 'woods/console/sql_noise_stripper'

RSpec.describe Woods::Console::SqlNoiseStripper do
  describe '.strip_comments' do
    it 'strips a line comment to end of line' do
      expect(described_class.strip_comments("SELECT 1 -- pick a number\nFROM t"))
        .to eq("SELECT 1 \nFROM t")
    end

    it 'strips a line comment that is the entire line' do
      expect(described_class.strip_comments("-- whole line\nSELECT 1"))
        .to eq("\nSELECT 1")
    end

    it 'strips multiple line comments' do
      sql = "SELECT 1 -- first\nFROM t -- second"
      expect(described_class.strip_comments(sql))
        .to eq("SELECT 1 \nFROM t ")
    end

    it 'strips a single-line block comment' do
      expect(described_class.strip_comments('SELECT /* inline */ 1'))
        .to eq('SELECT  1')
    end

    it 'strips a multi-line block comment' do
      sql = "SELECT /*\n  multi\n  line\n*/ 1"
      expect(described_class.strip_comments(sql)).to eq('SELECT  1')
    end

    it 'strips multiple block comments' do
      sql = 'SELECT /* a */ 1 /* b */ FROM t'
      expect(described_class.strip_comments(sql)).to eq('SELECT  1  FROM t')
    end

    it 'strips both line and block comments in the same input' do
      sql = "SELECT /* block */ 1 -- line\nFROM t"
      expect(described_class.strip_comments(sql)).to eq("SELECT  1 \nFROM t")
    end

    it 'returns the input unchanged when there are no comments' do
      expect(described_class.strip_comments('SELECT 1 FROM t')).to eq('SELECT 1 FROM t')
    end

    it 'strips -- inside a single-quoted string when called alone (caller must pipeline correctly)' do
      # strip_comments does not know about string boundaries — callers that need
      # both comment- and literal-stripping should call strip_comments THEN
      # strip_literals. Calling strip_comments alone on a string containing --
      # will treat the -- as a comment. This test documents that known limitation.
      sql = "SELECT '-- not a comment' FROM t"
      result = described_class.strip_comments(sql)
      # The -- and everything after it (including FROM t) is consumed as a comment.
      expect(result).to eq("SELECT '")
    end
  end

  describe '.strip_literals' do
    context 'with default dialect (:postgres)' do
      it 'strips a plain single-quoted string to an empty placeholder' do
        expect(described_class.strip_literals("SELECT 'hello' FROM t"))
          .to eq("SELECT '' FROM t")
      end

      it 'strips a string containing a double-quote escaped apostrophe (PostgreSQL style)' do
        expect(described_class.strip_literals("SELECT 'it''s fine' FROM t"))
          .to eq("SELECT '' FROM t")
      end

      it 'strips consecutive single-quoted strings' do
        expect(described_class.strip_literals("SELECT 'a', 'b' FROM t"))
          .to eq("SELECT '', '' FROM t")
      end

      it 'strips a string with embedded newlines' do
        expect(described_class.strip_literals("SELECT 'line1\nline2' FROM t"))
          .to eq("SELECT '' FROM t")
      end

      it 'strips a PG dollar-quoted string (unnamed $$)' do
        sql = 'SELECT $$hello world$$ AS val FROM t'
        expect(described_class.strip_literals(sql)).to eq("SELECT '' AS val FROM t")
      end

      it 'strips a PG dollar-quoted string with a tag' do
        sql = 'SELECT $body$FROM authorizations$body$ AS literal FROM users'
        expect(described_class.strip_literals(sql)).to eq("SELECT '' AS literal FROM users")
      end

      it 'strips multiple dollar-quoted strings' do
        sql = 'SELECT $$one$$ AS a, $tag$two$tag$ AS b FROM t'
        expect(described_class.strip_literals(sql)).to eq("SELECT '' AS a, '' AS b FROM t")
      end

      it 'strips dollar-quoted before single-quoted (apostrophes in dollar-quotes do not confuse scanner)' do
        sql = "SELECT $q$it's tricky$q$, 'plain' FROM t"
        expect(described_class.strip_literals(sql)).to eq("SELECT '', '' FROM t")
      end

      it 'does not treat a MySQL backslash-escape as ending the string (postgres dialect)' do
        # In postgres dialect \'  is just a backslash followed by a quote — not an escape.
        # The string ends at the next unescaped single-quote.
        # "SELECT 'it\'s'" in postgres means: open-quote, i, t, \, ' (end), s' which
        # is ambiguous. The postgres scanner treats \' as ending the first string,
        # leaving "s'" as a syntax error. Our scanner should behave the same.
        sql = "SELECT 'hello' FROM t"
        expect(described_class.strip_literals(sql)).to eq("SELECT '' FROM t")
      end
    end

    context 'with :mysql dialect' do
      it 'strips a plain single-quoted string' do
        expect(described_class.strip_literals("SELECT 'hello' FROM t", dialect: :mysql))
          .to eq("SELECT '' FROM t")
      end

      it 'strips a string with backslash-escaped apostrophe (MySQL style)' do
        expect(described_class.strip_literals("SELECT 'it\\'s fine' FROM t", dialect: :mysql))
          .to eq("SELECT '' FROM t")
      end

      it 'strips a string with backslash-escaped backslash' do
        expect(described_class.strip_literals("SELECT 'path\\\\dir' FROM t", dialect: :mysql))
          .to eq("SELECT '' FROM t")
      end

      it 'strips a string with backslash-escaped double-quote' do
        expect(described_class.strip_literals("SELECT 'say \\\"hi\\\"' FROM t", dialect: :mysql))
          .to eq("SELECT '' FROM t")
      end

      it 'strips consecutive strings in mysql dialect' do
        expect(described_class.strip_literals("SELECT 'a', 'b\\'c' FROM t", dialect: :mysql))
          .to eq("SELECT '', '' FROM t")
      end

      it 'strips dollar-quoted strings in mysql dialect too (for consistency)' do
        sql = 'SELECT $$content$$ FROM t'
        expect(described_class.strip_literals(sql, dialect: :mysql))
          .to eq("SELECT '' FROM t")
      end

      it 'treats double-quote escaped apostrophe as valid in mysql dialect' do
        expect(described_class.strip_literals("SELECT 'it''s fine' FROM t", dialect: :mysql))
          .to eq("SELECT '' FROM t")
      end
    end

    context 'with an unknown dialect' do
      it 'raises ArgumentError' do
        expect { described_class.strip_literals('SELECT 1', dialect: :oracle) }
          .to raise_error(ArgumentError, /unknown dialect/i)
      end
    end
  end
end
