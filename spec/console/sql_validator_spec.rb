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

    context 'with UNION injection' do
      it 'rejects SELECT with UNION' do
        expect { validator.validate!('SELECT 1 UNION SELECT password FROM users') }
          .to raise_error(CodebaseIndex::Console::SqlValidationError, /UNION/i)
      end

      it 'rejects SELECT with UNION ALL' do
        expect { validator.validate!('SELECT id FROM users UNION ALL SELECT id FROM admins') }
          .to raise_error(CodebaseIndex::Console::SqlValidationError, /UNION/i)
      end
    end

    context 'with writable CTEs' do
      it 'rejects WITH...DELETE' do
        expect { validator.validate!('WITH d AS (DELETE FROM users RETURNING *) SELECT * FROM d') }
          .to raise_error(CodebaseIndex::Console::SqlValidationError, /writable CTE/i)
      end

      it 'rejects WITH...UPDATE' do
        expect { validator.validate!('WITH u AS (UPDATE users SET admin=true RETURNING *) SELECT * FROM u') }
          .to raise_error(CodebaseIndex::Console::SqlValidationError, /writable CTE/i)
      end

      it 'rejects WITH...INSERT' do
        expect { validator.validate!('WITH i AS (INSERT INTO log(msg) VALUES (1) RETURNING *) SELECT * FROM i') }
          .to raise_error(CodebaseIndex::Console::SqlValidationError, /writable CTE/i)
      end
    end

    context 'with INTO OUTFILE / INTO DUMPFILE' do
      it 'rejects SELECT INTO' do
        expect { validator.validate!("SELECT * INTO OUTFILE '/tmp/evil' FROM users") }
          .to raise_error(CodebaseIndex::Console::SqlValidationError, /INTO/i)
      end
    end

    context 'with dangerous functions' do
      it 'rejects pg_sleep' do
        expect { validator.validate!('SELECT pg_sleep(999)') }
          .to raise_error(CodebaseIndex::Console::SqlValidationError, /dangerous function/i)
      end

      it 'rejects lo_import' do
        expect { validator.validate!("SELECT lo_import('/etc/passwd')") }
          .to raise_error(CodebaseIndex::Console::SqlValidationError, /dangerous function/i)
      end

      it 'rejects pg_read_file' do
        expect { validator.validate!("SELECT pg_read_file('/etc/passwd')") }
          .to raise_error(CodebaseIndex::Console::SqlValidationError, /dangerous function/i)
      end

      it 'rejects sleep (MySQL)' do
        expect { validator.validate!('SELECT sleep(10)') }
          .to raise_error(CodebaseIndex::Console::SqlValidationError, /dangerous function/i)
      end
    end

    context 'with comment-hidden semicolons' do
      it 'rejects semicolons hidden in line comments' do
        sql = "SELECT 1 --;\nDELETE FROM users"
        expect { validator.validate!(sql) }.to raise_error(CodebaseIndex::Console::SqlValidationError)
      end

      it 'rejects semicolons hidden in block comments' do
        sql = 'SELECT 1 /*;*/ DELETE FROM users'
        expect { validator.validate!(sql) }.to raise_error(CodebaseIndex::Console::SqlValidationError)
      end
    end

    context 'with legitimate SQL that should still pass' do
      it 'accepts WITH...SELECT (read-only CTE)' do
        expect { validator.validate!('WITH active AS (SELECT * FROM users WHERE active = true) SELECT * FROM active') }
          .not_to raise_error
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
