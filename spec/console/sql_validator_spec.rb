# frozen_string_literal: true

require 'spec_helper'
require 'codebase_index/console/sql_validator'

RSpec.describe CodebaseIndex::Console::SqlValidator do
  subject(:validator) { described_class.new }

  describe '#validate!' do
    context 'with allowed SELECT statements' do
      it 'accepts a simple SELECT' do
        expect { validator.validate!('SELECT * FROM users') }.not_to raise_error
      end

      it 'accepts SELECT with WHERE' do
        expect { validator.validate!('SELECT id, name FROM users WHERE active = true') }.not_to raise_error
      end

      it 'accepts SELECT with JOIN' do
        sql = 'SELECT u.id, p.title FROM users u JOIN posts p ON u.id = p.user_id'
        expect { validator.validate!(sql) }.not_to raise_error
      end

      it 'accepts SELECT with subquery' do
        sql = 'SELECT * FROM users WHERE id IN (SELECT user_id FROM posts)'
        expect { validator.validate!(sql) }.not_to raise_error
      end

      it 'accepts WITH...SELECT (CTE)' do
        sql = 'WITH active_users AS (SELECT * FROM users WHERE active = true) SELECT * FROM active_users'
        expect { validator.validate!(sql) }.not_to raise_error
      end

      it 'accepts case-insensitive SELECT' do
        expect { validator.validate!('select * from users') }.not_to raise_error
      end

      it 'accepts SELECT with leading whitespace' do
        expect { validator.validate!('  SELECT * FROM users') }.not_to raise_error
      end

      it 'accepts EXPLAIN SELECT' do
        expect { validator.validate!('EXPLAIN SELECT * FROM users') }.not_to raise_error
      end

      it 'accepts EXPLAIN ANALYZE SELECT' do
        expect { validator.validate!('EXPLAIN ANALYZE SELECT * FROM users') }.not_to raise_error
      end
    end

    context 'with rejected DML statements' do
      it 'rejects INSERT' do
        expect { validator.validate!("INSERT INTO users (name) VALUES ('test')") }
          .to raise_error(CodebaseIndex::Console::SqlValidationError, /INSERT/)
      end

      it 'rejects UPDATE' do
        expect { validator.validate!("UPDATE users SET name = 'x' WHERE id = 1") }
          .to raise_error(CodebaseIndex::Console::SqlValidationError, /UPDATE/)
      end

      it 'rejects DELETE' do
        expect { validator.validate!('DELETE FROM users WHERE id = 1') }
          .to raise_error(CodebaseIndex::Console::SqlValidationError, /DELETE/)
      end
    end

    context 'with rejected DDL statements' do
      it 'rejects DROP' do
        expect { validator.validate!('DROP TABLE users') }
          .to raise_error(CodebaseIndex::Console::SqlValidationError, /DROP/)
      end

      it 'rejects ALTER' do
        expect { validator.validate!('ALTER TABLE users ADD COLUMN age integer') }
          .to raise_error(CodebaseIndex::Console::SqlValidationError, /ALTER/)
      end

      it 'rejects TRUNCATE' do
        expect { validator.validate!('TRUNCATE users') }
          .to raise_error(CodebaseIndex::Console::SqlValidationError, /TRUNCATE/)
      end

      it 'rejects CREATE' do
        expect { validator.validate!('CREATE TABLE evil (id int)') }
          .to raise_error(CodebaseIndex::Console::SqlValidationError, /CREATE/)
      end
    end

    context 'with rejected administrative statements' do
      it 'rejects GRANT' do
        expect { validator.validate!('GRANT ALL ON users TO evil') }
          .to raise_error(CodebaseIndex::Console::SqlValidationError, /GRANT/)
      end

      it 'rejects REVOKE' do
        expect { validator.validate!('REVOKE ALL ON users FROM evil') }
          .to raise_error(CodebaseIndex::Console::SqlValidationError, /REVOKE/)
      end
    end

    context 'with case-insensitive rejection' do
      it 'rejects lowercase DML' do
        expect { validator.validate!("insert into users (name) values ('x')") }
          .to raise_error(CodebaseIndex::Console::SqlValidationError)
      end

      it 'rejects mixed-case DML' do
        expect { validator.validate!("Insert Into users (name) Values ('x')") }
          .to raise_error(CodebaseIndex::Console::SqlValidationError)
      end
    end

    context 'with embedded DML in string literals' do
      it 'rejects SELECT containing comment-based injection' do
        # Even if it looks like SELECT, semicolon-separated statements are rejected
        expect { validator.validate!('SELECT 1; DROP TABLE users') }
          .to raise_error(CodebaseIndex::Console::SqlValidationError, /multiple statements/i)
      end
    end

    context 'with multiple statements' do
      it 'rejects semicolon-separated statements' do
        expect { validator.validate!('SELECT 1; SELECT 2') }
          .to raise_error(CodebaseIndex::Console::SqlValidationError, /multiple statements/i)
      end
    end

    context 'with empty or nil input' do
      it 'rejects nil' do
        expect { validator.validate!(nil) }
          .to raise_error(CodebaseIndex::Console::SqlValidationError, /empty/i)
      end

      it 'rejects empty string' do
        expect { validator.validate!('') }
          .to raise_error(CodebaseIndex::Console::SqlValidationError, /empty/i)
      end

      it 'rejects whitespace-only string' do
        expect { validator.validate!('   ') }
          .to raise_error(CodebaseIndex::Console::SqlValidationError, /empty/i)
      end
    end
  end

  describe '#valid?' do
    it 'returns true for valid SELECT' do
      expect(validator.valid?('SELECT 1')).to be true
    end

    it 'returns false for INSERT' do
      expect(validator.valid?('INSERT INTO x VALUES (1)')).to be false
    end
  end
end
