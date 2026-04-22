# frozen_string_literal: true

require 'spec_helper'
require 'woods'
require 'woods/console/table_gate'

RSpec.describe Woods::Console::TableGate do
  describe 'DEFAULT_CONSOLE_BLOCKED_TABLES' do
    subject(:gate) do
      described_class.new(
        blocked_tables: Woods::DEFAULT_CONSOLE_BLOCKED_TABLES,
        model_tables: {}
      )
    end

    it 'is active (non-empty)' do
      expect(gate).to be_active
    end

    it 'blocks sessions' do
      expect { gate.check_sql!('SELECT * FROM sessions') }
        .to raise_error(Woods::Console::TableGateError, /sessions/)
    end

    it 'blocks api_keys' do
      expect { gate.check_sql!('SELECT * FROM api_keys') }
        .to raise_error(Woods::Console::TableGateError, /api_keys/)
    end

    it 'blocks credentials' do
      expect { gate.check_sql!('SELECT * FROM credentials') }
        .to raise_error(Woods::Console::TableGateError, /credentials/)
    end

    it 'blocks oauth_applications' do
      expect { gate.check_sql!('SELECT * FROM oauth_applications') }
        .to raise_error(Woods::Console::TableGateError, /oauth_applications/)
    end

    it 'blocks oauth_access_tokens' do
      expect { gate.check_sql!('SELECT * FROM oauth_access_tokens') }
        .to raise_error(Woods::Console::TableGateError, /oauth_access_tokens/)
    end

    it 'blocks oauth_refresh_tokens' do
      expect { gate.check_sql!('SELECT * FROM oauth_refresh_tokens') }
        .to raise_error(Woods::Console::TableGateError, /oauth_refresh_tokens/)
    end

    it 'blocks identities' do
      expect { gate.check_sql!('SELECT * FROM identities') }
        .to raise_error(Woods::Console::TableGateError, /identities/)
    end

    it 'blocks active_storage_blobs' do
      expect { gate.check_sql!('SELECT * FROM active_storage_blobs') }
        .to raise_error(Woods::Console::TableGateError, /active_storage_blobs/)
    end

    it 'allows safe non-auth tables (e.g. products)' do
      expect { gate.check_sql!('SELECT * FROM products') }.not_to raise_error
    end
  end

  describe '#check_sql!' do
    context 'when no tables are blocked' do
      let(:gate) { described_class.new(blocked_tables: [], model_tables: {}) }

      it 'allows any SELECT' do
        expect { gate.check_sql!('SELECT * FROM authorizations') }.not_to raise_error
      end

      it 'reports that the gate is inactive' do
        expect(gate).not_to be_active
      end

      it 'remains entirely inactive even when DEFAULT_CONSOLE_BLOCKED_TABLES is non-empty' do
        # Operators that explicitly set console_blocked_tables = [] intentionally
        # disable Layer 1. The gate must honour that choice and stay inactive.
        expect(Woods::DEFAULT_CONSOLE_BLOCKED_TABLES).not_to be_empty
        expect(gate).not_to be_active
      end
    end

    context 'when a table is blocked' do
      let(:gate) { described_class.new(blocked_tables: %w[authorizations], model_tables: {}) }

      it 'rejects a simple FROM reference' do
        expect { gate.check_sql!('SELECT * FROM authorizations') }
          .to raise_error(Woods::Console::TableGateError, /authorizations/)
      end

      it 'rejects case-insensitively' do
        expect { gate.check_sql!('SELECT * FROM Authorizations') }
          .to raise_error(Woods::Console::TableGateError)
      end

      it 'rejects a JOIN reference' do
        expect { gate.check_sql!('SELECT * FROM users JOIN authorizations ON users.id = authorizations.user_id') }
          .to raise_error(Woods::Console::TableGateError)
      end

      it 'rejects LEFT JOIN' do
        expect { gate.check_sql!('SELECT * FROM users LEFT JOIN authorizations ON users.id = authorizations.user_id') }
          .to raise_error(Woods::Console::TableGateError)
      end

      it 'rejects INNER JOIN' do
        expect { gate.check_sql!('SELECT * FROM users INNER JOIN authorizations ON users.id = authorizations.user_id') }
          .to raise_error(Woods::Console::TableGateError)
      end

      it 'rejects MySQL STRAIGHT_JOIN' do
        sql = 'SELECT * FROM users STRAIGHT_JOIN authorizations ON users.id = authorizations.user_id'
        expect { gate.check_sql!(sql) }
          .to raise_error(Woods::Console::TableGateError, /authorizations/)
      end

      it 'rejects backtick-quoted identifiers (MySQL)' do
        expect { gate.check_sql!('SELECT * FROM `authorizations`') }
          .to raise_error(Woods::Console::TableGateError)
      end

      it 'rejects double-quoted identifiers (PostgreSQL)' do
        expect { gate.check_sql!('SELECT * FROM "authorizations"') }
          .to raise_error(Woods::Console::TableGateError)
      end

      it 'rejects schema-qualified references' do
        expect { gate.check_sql!('SELECT * FROM public.authorizations') }
          .to raise_error(Woods::Console::TableGateError)
      end

      it 'rejects double-quoted schema-qualified references' do
        expect { gate.check_sql!('SELECT * FROM "public"."authorizations"') }
          .to raise_error(Woods::Console::TableGateError, /authorizations/)
      end

      it 'rejects backtick-quoted schema-qualified references (MySQL)' do
        expect { gate.check_sql!('SELECT * FROM `app`.`authorizations`') }
          .to raise_error(Woods::Console::TableGateError, /authorizations/)
      end

      it 'rejects double-quoted schema-qualified joins' do
        sql = 'SELECT * FROM "audit"."authorizations" ' \
              'JOIN users ON users.id = "audit"."authorizations".user_id'
        expect { gate.check_sql!(sql) }
          .to raise_error(Woods::Console::TableGateError, /authorizations/)
      end

      it 'rejects references hidden behind line comments that remove a safe statement' do
        sql = "SELECT * FROM users\n-- other comment\nJOIN authorizations ON users.id = authorizations.user_id"
        expect { gate.check_sql!(sql) }.to raise_error(Woods::Console::TableGateError)
      end

      it 'ignores blocked names hidden inside block comments' do
        sql = 'SELECT id FROM users /* FROM authorizations */ WHERE id = 1'
        expect { gate.check_sql!(sql) }.not_to raise_error
      end

      it 'ignores blocked names inside single-quoted string literals' do
        expect { gate.check_sql!("SELECT * FROM users WHERE name = 'authorizations'") }
          .not_to raise_error
      end

      it 'allows similarly-named tables that do not exactly match' do
        expect { gate.check_sql!('SELECT * FROM authorization_logs') }.not_to raise_error
        expect { gate.check_sql!('SELECT * FROM user_authorizations') }.not_to raise_error
      end

      it 'allows unrelated tables' do
        expect { gate.check_sql!('SELECT * FROM users JOIN orders ON users.id = orders.user_id') }
          .not_to raise_error
      end

      it 'rejects an ANSI-89 comma-join' do
        sql = 'SELECT * FROM users, authorizations WHERE users.id = authorizations.user_id'
        expect { gate.check_sql!(sql) }.to raise_error(Woods::Console::TableGateError, /authorizations/)
      end

      it 'rejects a comma-join regardless of position in the list' do
        sql = 'SELECT * FROM users, orders, authorizations'
        expect { gate.check_sql!(sql) }.to raise_error(Woods::Console::TableGateError)
      end

      it 'rejects a schema-qualified comma-join' do
        sql = 'SELECT * FROM users, public.authorizations'
        expect { gate.check_sql!(sql) }.to raise_error(Woods::Console::TableGateError)
      end

      it 'rejects a quoted comma-join' do
        sql = 'SELECT * FROM users, "authorizations"'
        expect { gate.check_sql!(sql) }.to raise_error(Woods::Console::TableGateError)
      end

      it 'ignores blocked names hidden inside a PG dollar-quoted literal' do
        sql = 'SELECT $tag$FROM authorizations$tag$ AS literal FROM users'
        expect { gate.check_sql!(sql) }.not_to raise_error
      end

      it 'ignores blocked names hidden inside an unnamed dollar-quoted literal' do
        sql = 'SELECT $$FROM authorizations$$ AS literal FROM users'
        expect { gate.check_sql!(sql) }.not_to raise_error
      end

      it 'rejects a blocked table inside a CTE body' do
        sql = 'WITH a AS (SELECT * FROM authorizations) SELECT * FROM a'
        expect { gate.check_sql!(sql) }
          .to raise_error(Woods::Console::TableGateError, /authorizations/)
      end

      it 'rejects a blocked table on the right side of UNION' do
        sql = 'SELECT id FROM users UNION SELECT id FROM authorizations'
        expect { gate.check_sql!(sql) }
          .to raise_error(Woods::Console::TableGateError, /authorizations/)
      end

      it 'rejects a blocked table in a FROM-clause subquery' do
        sql = 'SELECT * FROM (SELECT * FROM authorizations) AS a'
        expect { gate.check_sql!(sql) }
          .to raise_error(Woods::Console::TableGateError, /authorizations/)
      end

      it 'rejects FROM ONLY <table> (PostgreSQL inheritance keyword)' do
        expect { gate.check_sql!('SELECT * FROM ONLY authorizations') }
          .to raise_error(Woods::Console::TableGateError, /authorizations/)
      end

      it 'rejects JOIN ONLY <table>' do
        sql = 'SELECT * FROM users JOIN ONLY authorizations ON users.id = authorizations.user_id'
        expect { gate.check_sql!(sql) }
          .to raise_error(Woods::Console::TableGateError, /authorizations/)
      end

      it 'rejects mixed bare-schema with quoted table in FROM' do
        expect { gate.check_sql!('SELECT * FROM audit."authorizations"') }
          .to raise_error(Woods::Console::TableGateError, /authorizations/)
      end

      it 'rejects mixed bare-schema with quoted table in JOIN' do
        sql = 'SELECT * FROM users JOIN audit."authorizations" ON users.id = ' \
              'audit."authorizations".user_id'
        expect { gate.check_sql!(sql) }
          .to raise_error(Woods::Console::TableGateError, /authorizations/)
      end
    end

    context 'when a schema-qualified entry is on the block list' do
      let(:gate) do
        described_class.new(blocked_tables: %w[audit.authorizations], model_tables: {})
      end

      it 'rejects the matching schema-qualified bare reference' do
        expect { gate.check_sql!('SELECT * FROM audit.authorizations') }
          .to raise_error(Woods::Console::TableGateError, /audit\.authorizations/i)
      end

      it 'rejects the matching schema-qualified double-quoted reference' do
        expect { gate.check_sql!('SELECT * FROM "audit"."authorizations"') }
          .to raise_error(Woods::Console::TableGateError, /audit\.authorizations/i)
      end

      it 'rejects the matching schema-qualified backtick reference (MySQL)' do
        expect { gate.check_sql!('SELECT * FROM `audit`.`authorizations`') }
          .to raise_error(Woods::Console::TableGateError, /audit\.authorizations/i)
      end

      it 'rejects bare schema with quoted table' do
        expect { gate.check_sql!('SELECT * FROM audit."authorizations"') }
          .to raise_error(Woods::Console::TableGateError, /audit\.authorizations/i)
      end

      it 'allows references in a different schema' do
        expect { gate.check_sql!('SELECT * FROM public.authorizations') }.not_to raise_error
        expect { gate.check_sql!('SELECT * FROM "public"."authorizations"') }.not_to raise_error
      end

      it 'allows the bare table name (no schema)' do
        expect { gate.check_sql!('SELECT * FROM authorizations') }.not_to raise_error
      end
    end

    context 'when a bare entry is on the block list' do
      let(:gate) do
        described_class.new(blocked_tables: %w[authorizations], model_tables: {})
      end

      it 'continues to reject the bare reference' do
        expect { gate.check_sql!('SELECT * FROM authorizations') }
          .to raise_error(Woods::Console::TableGateError)
      end

      it 'continues to reject every schema-qualified variant (wildcard)' do
        expect { gate.check_sql!('SELECT * FROM public.authorizations') }
          .to raise_error(Woods::Console::TableGateError)
        expect { gate.check_sql!('SELECT * FROM audit.authorizations') }
          .to raise_error(Woods::Console::TableGateError)
        expect { gate.check_sql!('SELECT * FROM "public"."authorizations"') }
          .to raise_error(Woods::Console::TableGateError)
      end
    end

    context 'when multiple tables are blocked' do
      let(:gate) do
        described_class.new(blocked_tables: %w[authorizations secrets credentials], model_tables: {})
      end

      it 'rejects any one of them' do
        expect { gate.check_sql!('SELECT * FROM secrets') }
          .to raise_error(Woods::Console::TableGateError, /secrets/)
      end

      it 'names the blocked table in the error message' do
        expect { gate.check_sql!('SELECT * FROM credentials') }
          .to raise_error(Woods::Console::TableGateError, /credentials/)
      end
    end
  end

  describe '#check_model!' do
    let(:gate) do
      described_class.new(
        blocked_tables: %w[authorizations],
        model_tables: { 'Authorization' => 'authorizations', 'User' => 'users' }
      )
    end

    it 'rejects a model whose table is blocked' do
      expect { gate.check_model!('Authorization') }
        .to raise_error(Woods::Console::TableGateError, /authorizations/)
    end

    it 'allows a model whose table is not blocked' do
      expect { gate.check_model!('User') }.not_to raise_error
    end

    it 'passes through unknown model names (model validation happens elsewhere)' do
      expect { gate.check_model!('MysteryModel') }.not_to raise_error
    end

    it 'matches blocked names case-insensitively' do
      gate = described_class.new(
        blocked_tables: %w[Authorizations],
        model_tables: { 'Authorization' => 'authorizations' }
      )
      expect { gate.check_model!('Authorization') }.to raise_error(Woods::Console::TableGateError)
    end
  end

  describe '#check_joins!' do
    let(:gate) do
      described_class.new(
        blocked_tables: %w[authorizations],
        model_tables: { 'User' => 'users', 'Order' => 'orders' },
        model_reflections: {
          'User' => { 'authorizations' => 'authorizations', 'orders' => 'orders' },
          'Order' => { 'user' => 'users' }
        }
      )
    end

    it 'rejects a join whose target table is blocked' do
      expect { gate.check_joins!('User', [:authorizations]) }
        .to raise_error(Woods::Console::TableGateError, /authorizations/)
    end

    it 'rejects a join passed as a string' do
      expect { gate.check_joins!('User', ['authorizations']) }
        .to raise_error(Woods::Console::TableGateError)
    end

    it 'allows non-blocked joins' do
      expect { gate.check_joins!('User', [:orders]) }.not_to raise_error
    end

    it 'passes through unknown join names' do
      expect { gate.check_joins!('User', [:unknown_assoc]) }.not_to raise_error
    end

    it 'is a no-op when joins is nil or empty' do
      expect { gate.check_joins!('User', nil) }.not_to raise_error
      expect { gate.check_joins!('User', []) }.not_to raise_error
    end
  end

  describe '#check_association!' do
    let(:gate) do
      described_class.new(
        blocked_tables: %w[authorizations],
        model_tables: { 'User' => 'users' },
        model_reflections: { 'User' => { 'authorizations' => 'authorizations', 'orders' => 'orders' } }
      )
    end

    it 'rejects an association whose target table is blocked' do
      expect { gate.check_association!('User', :authorizations) }
        .to raise_error(Woods::Console::TableGateError)
    end

    it 'allows a non-blocked association' do
      expect { gate.check_association!('User', :orders) }.not_to raise_error
    end

    it 'is a no-op when association is nil' do
      expect { gate.check_association!('User', nil) }.not_to raise_error
    end
  end

  describe '#check_table!' do
    let(:gate) { described_class.new(blocked_tables: %w[authorizations], model_tables: {}) }

    it 'rejects the exact blocked name' do
      expect { gate.check_table!('authorizations') }
        .to raise_error(Woods::Console::TableGateError)
    end

    it 'is case-insensitive' do
      expect { gate.check_table!('Authorizations') }
        .to raise_error(Woods::Console::TableGateError)
    end

    it 'allows non-blocked tables' do
      expect { gate.check_table!('users') }.not_to raise_error
    end

    it 'strips schema prefix before comparing' do
      expect { gate.check_table!('public.authorizations') }
        .to raise_error(Woods::Console::TableGateError)
    end

    it 'is a no-op on empty input' do
      expect { gate.check_table!(nil) }.not_to raise_error
    end
  end
end
