# frozen_string_literal: true

require 'spec_helper'
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
