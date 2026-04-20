# frozen_string_literal: true

require 'spec_helper'
require 'woods/console/table_gate'

RSpec.describe Woods::Console::TableGate do
  describe '#check_sql!' do
    context 'when no tables are blocked' do
      let(:gate) { described_class.new(blocked_tables: [], model_tables: {}) }

      it 'allows any SELECT' do
        expect { gate.check_sql!('SELECT * FROM authorizations') }.not_to raise_error
      end

      it 'reports that the gate is inactive' do
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
      expect(gate.check_joins!('User', nil)).to be(true)
      expect(gate.check_joins!('User', [])).to be(true)
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
      expect(gate.check_association!('User', nil)).to be(true)
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

    it 'returns true on empty input (no-op)' do
      expect(gate.check_table!(nil)).to be(true)
    end
  end
end
