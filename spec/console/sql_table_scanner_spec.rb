# frozen_string_literal: true

require 'spec_helper'
require 'woods'
require 'woods/console/sql_table_scanner'

RSpec.describe Woods::Console::SqlTableScanner do
  describe '.identifiers_in' do
    subject(:identifiers) { described_class.identifiers_in(sql) }

    context 'with simple FROM clauses' do
      let(:sql) { 'SELECT * FROM users' }

      it 'returns the table name' do
        expect(identifiers).to include('users')
      end

      it 'returns an array' do
        expect(identifiers).to be_an(Array)
      end
    end

    context 'with no FROM or JOIN' do
      let(:sql) { 'SELECT 1' }

      it 'returns an empty array' do
        expect(identifiers).to eq([])
      end
    end

    context 'with a FROM clause hidden by MySQL-only escape rules (PostgreSQL bypass)' do
      # On PostgreSQL (standard_conforming_strings on), backslash is
      # literal: the server parses `'x\'` as one literal and genuinely
      # reads FROM blocked. Stripping with only the MySQL dialect (where
      # \' continues the string) folded the real FROM clause into a
      # literal, hiding the table from TableGate.
      let(:sql) { %q(SELECT 'x\' FROM blocked WHERE secret LIKE 'a%') }

      it 'still detects the table read by a PostgreSQL server' do
        expect(identifiers).to include('blocked')
      end
    end

    context 'with nil input' do
      let(:sql) { nil }

      it 'returns an empty array' do
        expect(identifiers).to eq([])
      end
    end

    context 'with an empty string' do
      let(:sql) { '' }

      it 'returns an empty array' do
        expect(identifiers).to eq([])
      end
    end

    context 'with JOIN references' do
      let(:sql) { 'SELECT * FROM users JOIN orders ON users.id = orders.user_id' }

      it 'includes the FROM table' do
        expect(identifiers).to include('users')
      end

      it 'includes the JOIN table' do
        expect(identifiers).to include('orders')
      end
    end

    context 'with LEFT JOIN' do
      let(:sql) { 'SELECT * FROM users LEFT JOIN orders ON users.id = orders.user_id' }

      it 'includes both tables' do
        expect(identifiers).to include('users', 'orders')
      end
    end

    context 'with INNER JOIN' do
      let(:sql) { 'SELECT * FROM users INNER JOIN orders ON users.id = orders.user_id' }

      it 'includes both tables' do
        expect(identifiers).to include('users', 'orders')
      end
    end

    context 'with MySQL STRAIGHT_JOIN' do
      let(:sql) { 'SELECT * FROM users STRAIGHT_JOIN authorizations ON users.id = authorizations.user_id' }

      it 'includes the STRAIGHT_JOIN target' do
        expect(identifiers).to include('authorizations')
      end
    end

    context 'with backtick-quoted identifiers (MySQL)' do
      let(:sql) { 'SELECT * FROM `authorizations`' }

      it 'returns the unquoted identifier' do
        expect(identifiers).to include('authorizations')
      end
    end

    context 'with double-quoted identifiers (PostgreSQL)' do
      let(:sql) { 'SELECT * FROM "authorizations"' }

      it 'returns the unquoted identifier' do
        expect(identifiers).to include('authorizations')
      end
    end

    context 'with schema-qualified references' do
      let(:sql) { 'SELECT * FROM public.authorizations' }

      it 'returns the qualified identifier' do
        expect(identifiers).to include('public.authorizations')
      end
    end

    context 'with double-quoted schema-qualified references' do
      let(:sql) { 'SELECT * FROM "audit"."authorizations"' }

      it 'returns the qualified identifier' do
        expect(identifiers).to include('audit.authorizations')
      end
    end

    context 'with backtick-quoted schema-qualified references (MySQL)' do
      let(:sql) { 'SELECT * FROM `app`.`authorizations`' }

      it 'returns the qualified identifier' do
        expect(identifiers).to include('app.authorizations')
      end
    end

    context 'with ANSI-89 comma joins' do
      let(:sql) { 'SELECT * FROM users, orders, products' }

      it 'returns all tables in the comma-join list' do
        expect(identifiers).to include('users', 'orders', 'products')
      end
    end

    context 'with a schema-qualified comma join' do
      let(:sql) { 'SELECT * FROM users, public.authorizations' }

      it 'includes the qualified comma-joined table' do
        expect(identifiers).to include('public.authorizations')
      end
    end

    context 'with FROM ONLY (PostgreSQL inheritance keyword)' do
      let(:sql) { 'SELECT * FROM ONLY authorizations' }

      it 'returns the table name without the ONLY keyword' do
        expect(identifiers).to include('authorizations')
        expect(identifiers).not_to include('only')
      end
    end

    context 'with JOIN ONLY (PostgreSQL inheritance keyword)' do
      let(:sql) { 'SELECT * FROM users JOIN ONLY authorizations ON users.id = authorizations.user_id' }

      it 'returns the ONLY target table name' do
        expect(identifiers).to include('authorizations')
      end
    end

    context 'with CTE bodies' do
      let(:sql) { 'WITH a AS (SELECT * FROM authorizations) SELECT * FROM a' }

      it 'includes tables inside the CTE body' do
        expect(identifiers).to include('authorizations')
      end
    end

    context 'with UNION' do
      let(:sql) { 'SELECT id FROM users UNION SELECT id FROM authorizations' }

      it 'includes tables from both sides of the UNION' do
        expect(identifiers).to include('users', 'authorizations')
      end
    end

    context 'with FROM-clause subquery' do
      let(:sql) { 'SELECT * FROM (SELECT * FROM authorizations) AS a' }

      it 'includes the table inside the subquery' do
        expect(identifiers).to include('authorizations')
      end
    end

    context 'when content is hidden inside comments' do
      let(:sql) { 'SELECT id FROM users /* FROM authorizations */ WHERE id = 1' }

      it 'does not return identifiers from block comments' do
        expect(identifiers).not_to include('authorizations')
      end
    end

    context 'when content is hidden inside single-quoted literals' do
      let(:sql) { "SELECT * FROM users WHERE name = 'authorizations'" }

      it 'does not return identifiers from string literals' do
        expect(identifiers).not_to include('authorizations')
      end
    end

    context 'when a comment marker sits inside a string literal (must not hide FROM)' do
      # The `--` is inside a literal, so it is NOT a comment: the real
      # `FROM blocked` must be detected. Stripping comments before literals
      # swallowed it, letting a blocked table slip past TableGate.
      let(:sql) { "SELECT 'a -- b' FROM blocked" }

      it 'still detects the real table after the literal' do
        expect(identifiers).to include('blocked')
      end
    end

    context 'when an apostrophe sits inside a line comment (must not hide FROM)' do
      let(:sql) { "SELECT 1 -- it's fine\nFROM real_table" }

      it 'detects the table on the line after the comment' do
        expect(identifiers).to include('real_table')
      end
    end

    context 'with an unterminated block comment (must never under-detect)' do
      # A `/*` with no closing `*/` must not swallow the rest of the statement
      # — over-detection is safe for the gate, under-detection is not.
      let(:sql) { 'SELECT 1 /* FROM blocked' }

      it 'still surfaces the table after the unterminated comment' do
        expect(identifiers).to include('blocked')
      end
    end

    context 'when content is hidden inside PG dollar-quoted literals' do
      let(:sql) { 'SELECT $tag$FROM authorizations$tag$ AS literal FROM users' }

      it 'does not return identifiers from dollar-quoted literals' do
        expect(identifiers).not_to include('authorizations')
      end

      it 'still returns the real table' do
        expect(identifiers).to include('users')
      end
    end

    context 'when content is hidden inside unnamed dollar-quoted literals' do
      let(:sql) { 'SELECT $$FROM authorizations$$ AS literal FROM users' }

      it 'does not return identifiers from unnamed dollar-quoted literals' do
        expect(identifiers).not_to include('authorizations')
      end
    end

    context 'with MySQL backslash escapes in string literals' do
      let(:sql) { "SELECT * FROM users WHERE name = 'it\\'s ok'" }

      it 'does not extract from inside escaped string literals' do
        # The string content is stripped — only real table names remain
        expect(identifiers).to eq(['users'])
      end
    end

    context 'with mixed bare-schema and quoted table in FROM' do
      let(:sql) { 'SELECT * FROM audit."authorizations"' }

      it 'returns the qualified identifier' do
        expect(identifiers).to include('audit.authorizations')
      end
    end

    context 'with line comments containing SQL' do
      let(:sql) { "SELECT * FROM users\n-- FROM authorizations\nWHERE id = 1" }

      it 'does not return identifiers from line comments' do
        expect(identifiers).not_to include('authorizations')
      end

      it 'still returns real tables' do
        expect(identifiers).to include('users')
      end
    end

    context 'with a MySQL executable comment (/*! ... */) hiding a table (must not hide FROM)' do
      # MySQL executes the body of a /*! ... */ comment — it is not inert like
      # an ordinary block comment. Stripping it as a normal comment let a
      # blocked table slip past TableGate.
      let(:sql) { 'SELECT * FROM t /*! , blocked */' }

      it 'detects the table hidden inside the executable comment' do
        expect(identifiers).to include('blocked')
      end
    end

    context 'with a MySQL executable comment around a dangerous expression' do
      let(:sql) { 'SELECT 1 /*! , SLEEP(10) */ FROM blocked' }

      it 'still detects the real table' do
        expect(identifiers).to include('blocked')
      end
    end

    context 'with a MySQL # line comment confusing the quote scanner (must not hide FROM)' do
      # Without # comment support the stripper misreads the apostrophe
      # inside the comment as opening a string literal, swallowing the
      # real FROM clause that follows into a fake literal.
      let(:sql) { "SELECT * FROM t # 'x\n, blocked WHERE b = 'z'" }

      it 'detects the table after the # comment' do
        expect(identifiers).to include('blocked')
      end
    end

    context 'with the SQL TABLE statement (PostgreSQL / MySQL 8.0.19+)' do
      let(:sql) { 'WITH x AS (TABLE blocked) SELECT * FROM x' }

      it 'detects the table referenced via TABLE' do
        expect(identifiers).to include('blocked')
      end
    end

    context 'with a TABLE statement inside a FROM subquery' do
      let(:sql) { 'SELECT * FROM (TABLE blocked) AS t' }

      it 'detects the table referenced via TABLE' do
        expect(identifiers).to include('blocked')
      end
    end

    context 'with a $ inside an identifier that is not a dollar-quote tag (must not hide FROM)' do
      # PostgreSQL allows `$` inside identifiers. Treating a `$` that
      # follows a word character as a dollar-quote opener hid the real
      # FROM clause between two `$`-suffixed identifiers.
      let(:sql) { 'SELECT t.id AS x$a$ FROM blocked t, (SELECT 1 AS z$a$) s' }

      it 'detects the table hidden between the dollar-suffixed identifiers' do
        expect(identifiers).to include('blocked')
      end
    end

    context 'with a complex multi-join query' do
      let(:sql) do
        <<~SQL
          SELECT u.id, o.id, p.name
          FROM users u
          JOIN orders o ON o.user_id = u.id
          JOIN order_items oi ON oi.order_id = o.id
          JOIN products p ON p.id = oi.product_id
          WHERE u.created_at > '2024-01-01'
        SQL
      end

      it 'returns all joined tables' do
        expect(identifiers).to include('users', 'orders', 'order_items', 'products')
      end
    end
  end
end
