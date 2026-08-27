# frozen_string_literal: true

require 'spec_helper'
require 'woods'
require 'woods/console/sql_validator'

RSpec.describe Woods::Console::SqlValidator do
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

      it 'rejects EXPLAIN ANALYZE (actually executes the plan on PG/MySQL 8)' do
        expect { validator.validate!('EXPLAIN ANALYZE SELECT * FROM users') }
          .to raise_error(Woods::Console::SqlValidationError)
      end

      it 'rejects EXPLAIN ANALYSE (PostgreSQL accepts the British spelling too)' do
        expect { validator.validate!('EXPLAIN ANALYSE SELECT * FROM users') }
          .to raise_error(Woods::Console::SqlValidationError)
      end
    end

    context 'with rejected DML statements' do
      it 'rejects INSERT' do
        expect { validator.validate!("INSERT INTO users (name) VALUES ('test')") }
          .to raise_error(Woods::Console::SqlValidationError, /INSERT/)
      end

      it 'rejects UPDATE' do
        expect { validator.validate!("UPDATE users SET name = 'x' WHERE id = 1") }
          .to raise_error(Woods::Console::SqlValidationError, /UPDATE/)
      end

      it 'rejects DELETE' do
        expect { validator.validate!('DELETE FROM users WHERE id = 1') }
          .to raise_error(Woods::Console::SqlValidationError, /DELETE/)
      end
    end

    context 'with rejected DDL statements' do
      it 'rejects DROP' do
        expect { validator.validate!('DROP TABLE users') }
          .to raise_error(Woods::Console::SqlValidationError, /DROP/)
      end

      it 'rejects ALTER' do
        expect { validator.validate!('ALTER TABLE users ADD COLUMN age integer') }
          .to raise_error(Woods::Console::SqlValidationError, /ALTER/)
      end

      it 'rejects TRUNCATE' do
        expect { validator.validate!('TRUNCATE users') }
          .to raise_error(Woods::Console::SqlValidationError, /TRUNCATE/)
      end

      it 'rejects CREATE' do
        expect { validator.validate!('CREATE TABLE evil (id int)') }
          .to raise_error(Woods::Console::SqlValidationError, /CREATE/)
      end
    end

    context 'with rejected administrative statements' do
      it 'rejects GRANT' do
        expect { validator.validate!('GRANT ALL ON users TO evil') }
          .to raise_error(Woods::Console::SqlValidationError, /GRANT/)
      end

      it 'rejects REVOKE' do
        expect { validator.validate!('REVOKE ALL ON users FROM evil') }
          .to raise_error(Woods::Console::SqlValidationError, /REVOKE/)
      end
    end

    context 'with case-insensitive rejection' do
      it 'rejects lowercase DML' do
        expect { validator.validate!("insert into users (name) values ('x')") }
          .to raise_error(Woods::Console::SqlValidationError)
      end

      it 'rejects mixed-case DML' do
        expect { validator.validate!("Insert Into users (name) Values ('x')") }
          .to raise_error(Woods::Console::SqlValidationError)
      end
    end

    context 'with embedded DML in string literals' do
      it 'rejects SELECT containing comment-based injection' do
        # Even if it looks like SELECT, semicolon-separated statements are rejected
        expect { validator.validate!('SELECT 1; DROP TABLE users') }
          .to raise_error(Woods::Console::SqlValidationError, /multiple statements/i)
      end
    end

    context 'with multiple statements' do
      it 'rejects semicolon-separated statements' do
        expect { validator.validate!('SELECT 1; SELECT 2') }
          .to raise_error(Woods::Console::SqlValidationError, /multiple statements/i)
      end
    end

    context 'with UNION injection' do
      it 'rejects SELECT with UNION' do
        expect { validator.validate!('SELECT 1 UNION SELECT password FROM users') }
          .to raise_error(Woods::Console::SqlValidationError, /UNION/i)
      end

      it 'rejects SELECT with UNION ALL' do
        expect { validator.validate!('SELECT id FROM users UNION ALL SELECT id FROM admins') }
          .to raise_error(Woods::Console::SqlValidationError, /UNION/i)
      end
    end

    context 'with other set operators' do
      it 'rejects SELECT with INTERSECT' do
        expect { validator.validate!('SELECT id FROM users INTERSECT SELECT id FROM admins') }
          .to raise_error(Woods::Console::SqlValidationError, /INTERSECT/i)
      end

      it 'rejects SELECT with EXCEPT' do
        expect { validator.validate!('SELECT id FROM users EXCEPT SELECT id FROM admins') }
          .to raise_error(Woods::Console::SqlValidationError, /EXCEPT/i)
      end
    end

    context 'with writable CTEs' do
      it 'rejects WITH...DELETE' do
        expect { validator.validate!('WITH d AS (DELETE FROM users RETURNING *) SELECT * FROM d') }
          .to raise_error(Woods::Console::SqlValidationError, /writable CTE/i)
      end

      it 'rejects WITH...UPDATE' do
        expect { validator.validate!('WITH u AS (UPDATE users SET admin=true RETURNING *) SELECT * FROM u') }
          .to raise_error(Woods::Console::SqlValidationError, /writable CTE/i)
      end

      it 'rejects WITH...INSERT' do
        expect { validator.validate!('WITH i AS (INSERT INTO log(msg) VALUES (1) RETURNING *) SELECT * FROM i') }
          .to raise_error(Woods::Console::SqlValidationError, /writable CTE/i)
      end

      it 'rejects WITH RECURSIVE...DELETE with the writable CTE message' do
        sql = 'WITH RECURSIVE d AS (DELETE FROM users RETURNING *) SELECT * FROM d'
        expect { validator.validate!(sql) }.to raise_error(Woods::Console::SqlValidationError, /writable CTE/i)
      end
    end

    context 'with INTO OUTFILE / INTO DUMPFILE' do
      it 'rejects SELECT INTO' do
        expect { validator.validate!("SELECT * INTO OUTFILE '/tmp/evil' FROM users") }
          .to raise_error(Woods::Console::SqlValidationError, /INTO/i)
      end
    end

    context 'with dangerous functions' do
      it 'rejects pg_sleep' do
        expect { validator.validate!('SELECT pg_sleep(999)') }
          .to raise_error(Woods::Console::SqlValidationError, /dangerous function/i)
      end

      it 'rejects lo_import' do
        expect { validator.validate!("SELECT lo_import('/etc/passwd')") }
          .to raise_error(Woods::Console::SqlValidationError, /dangerous function/i)
      end

      it 'rejects pg_read_file' do
        expect { validator.validate!("SELECT pg_read_file('/etc/passwd')") }
          .to raise_error(Woods::Console::SqlValidationError, /dangerous function/i)
      end

      it 'rejects sleep (MySQL)' do
        expect { validator.validate!('SELECT sleep(10)') }
          .to raise_error(Woods::Console::SqlValidationError, /dangerous function/i)
      end
    end

    context 'with comment-hidden semicolons' do
      it 'rejects semicolons hidden in line comments' do
        sql = "SELECT 1 --;\nDELETE FROM users"
        expect { validator.validate!(sql) }.to raise_error(Woods::Console::SqlValidationError)
      end

      it 'rejects semicolons hidden in block comments' do
        sql = 'SELECT 1 /*;*/ DELETE FROM users'
        expect { validator.validate!(sql) }.to raise_error(Woods::Console::SqlValidationError)
      end
    end

    context 'with legitimate SQL that should still pass' do
      it 'accepts WITH...SELECT (read-only CTE)' do
        expect { validator.validate!('WITH active AS (SELECT * FROM users WHERE active = true) SELECT * FROM active') }
          .not_to raise_error
      end
    end

    context 'with a keyword-shaped English word inside a string literal' do
      it 'accepts a WHERE clause on a literal value containing UPDATE' do
        sql = "SELECT * FROM notes WHERE body = 'please update the record'"
        expect { validator.validate!(sql) }.not_to raise_error
      end

      it 'accepts a WHERE clause on a literal value containing INTO' do
        sql = "SELECT * FROM notes WHERE body = 'insight into the problem'"
        expect { validator.validate!(sql) }.not_to raise_error
      end

      it 'accepts a WHERE clause on a literal value that names a dangerous function' do
        sql = "SELECT * FROM notes WHERE body = 'we discussed pg_sleep(10) in the meeting'"
        expect { validator.validate!(sql) }.not_to raise_error
      end

      it 'still rejects DELETE hidden after a line comment (comment-hidden injection)' do
        sql = "SELECT 1 --;\nDELETE FROM users"
        expect { validator.validate!(sql) }.to raise_error(Woods::Console::SqlValidationError, /DELETE/)
      end
    end

    context 'with empty or nil input' do
      it 'rejects nil' do
        expect { validator.validate!(nil) }
          .to raise_error(Woods::Console::SqlValidationError, /empty/i)
      end

      it 'rejects empty string' do
        expect { validator.validate!('') }
          .to raise_error(Woods::Console::SqlValidationError, /empty/i)
      end

      it 'rejects whitespace-only string' do
        expect { validator.validate!('   ') }
          .to raise_error(Woods::Console::SqlValidationError, /empty/i)
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

  describe 'expanded forbidden prefixes (release-prep hardening)' do
    %w[
      DO CALL SET RESET LISTEN NOTIFY VACUUM ANALYZE CLUSTER REINDEX
      REFRESH LOCK PREPARE EXECUTE DEALLOCATE BEGIN COMMIT ROLLBACK
      SAVEPOINT RELEASE START LOAD HANDLER
    ].each do |keyword|
      it "rejects #{keyword} statements" do
        expect { validator.validate!("#{keyword} something") }
          .to raise_error(Woods::Console::SqlValidationError)
      end
    end

    it 'rejects EXPLAIN ANALYZE SELECT (actually executes on PG)' do
      expect { validator.validate!('EXPLAIN ANALYZE SELECT 1') }
        .to raise_error(Woods::Console::SqlValidationError)
    end

    it 'still accepts plain EXPLAIN SELECT' do
      expect { validator.validate!('EXPLAIN SELECT 1') }.not_to raise_error
    end

    it 'rejects MERGE by name (defense in depth beyond the allowed-prefix fallback)' do
      sql = 'MERGE INTO target USING source ON (target.id = source.id) WHEN MATCHED THEN UPDATE SET x = 1'
      expect { validator.validate!(sql) }.to raise_error(Woods::Console::SqlValidationError, /MERGE/)
    end
  end

  describe 'forbidden keyword false positives on identifier-shaped column names' do
    # FORBIDDEN_BODY_REGEXES used to match a bare word anywhere in the
    # stripped body, so a column legitimately named after a forbidden
    # keyword (do, start, release, lock, handler, ...) was rejected even
    # though it was never used as a statement. Only a statement-leader
    # position (start of the SQL, or right after a `;`/comment-preserved
    # boundary) should count.
    %w[do start release lock handler].each do |column|
      it "accepts a WHERE clause comparing the column `#{column}`" do
        sql = "SELECT * FROM t WHERE #{column} = 1"
        expect { validator.validate!(sql) }.not_to raise_error
      end
    end

    it 'accepts a SELECT list containing a column named after a forbidden keyword' do
      expect { validator.validate!('SELECT id, start, release FROM events') }.not_to raise_error
    end

    it 'still rejects DELETE hidden after a line comment (comment-hidden injection)' do
      sql = "SELECT 1 --;\nDELETE FROM users"
      expect { validator.validate!(sql) }.to raise_error(Woods::Console::SqlValidationError, /DELETE/)
    end

    it 'still rejects DELETE hidden after a block comment containing a semicolon' do
      sql = 'SELECT 1 /*;*/ DELETE FROM users'
      expect { validator.validate!(sql) }.to raise_error(Woods::Console::SqlValidationError)
    end

    it 'still rejects a forbidden keyword at the very start of the statement' do
      expect { validator.validate!('LOCK TABLE users') }
        .to raise_error(Woods::Console::SqlValidationError, /LOCK/)
    end
  end

  describe 'function allowlist (read-only policy)' do
    context 'with rejected side-effecting functions' do
      it 'rejects pg_terminate_backend' do
        expect { validator.validate!('SELECT pg_terminate_backend(pid) FROM pg_stat_activity') }
          .to raise_error(Woods::Console::SqlValidationError, /pg_terminate_backend/)
      end

      it 'rejects pg_advisory_lock' do
        expect { validator.validate!('SELECT pg_advisory_lock(1)') }
          .to raise_error(Woods::Console::SqlValidationError, /pg_advisory_lock/)
      end

      it 'rejects nextval' do
        expect { validator.validate!("SELECT nextval('users_id_seq')") }
          .to raise_error(Woods::Console::SqlValidationError, /nextval/)
      end

      it 'rejects setval' do
        expect { validator.validate!("SELECT setval('users_id_seq', 1)") }
          .to raise_error(Woods::Console::SqlValidationError, /setval/)
      end

      it 'rejects an arbitrary unknown function' do
        expect { validator.validate!('SELECT some_unknown_function(1)') }
          .to raise_error(Woods::Console::SqlValidationError, /some_unknown_function/)
      end

      it 'names the rejected function and how to proceed' do
        expect { validator.validate!('SELECT pg_terminate_backend(1)') }
          .to raise_error(Woods::Console::SqlValidationError, /allowlist/i)
      end
    end

    context 'with allowed pure/read functions' do
      [
        'count(*)', 'sum(amount)', 'avg(amount)', 'min(amount)', 'max(amount)',
        "coalesce(name,'x')", 'nullif(a,b)', 'lower(name)', 'upper(name)', 'length(name)',
        'substr(name,1,2)', 'substring(name,1,2)', 'trim(name)', 'abs(amount)', 'round(amount)',
        'cast(amount as integer)'
      ].each do |expr|
        it "accepts #{expr}" do
          expect { validator.validate!("SELECT #{expr} FROM orders") }.not_to raise_error
        end
      end
    end

    context 'with functions already covered by the dangerous-function denylist' do
      it 'still rejects pg_sleep with an allowlist-consistent message' do
        expect { validator.validate!('SELECT pg_sleep(999)') }
          .to raise_error(Woods::Console::SqlValidationError)
      end
    end

    context 'with a quoted identifier wrapping a forbidden function' do
      [
        'SELECT "pg_terminate_backend"(12345)',
        'SELECT pg_catalog."pg_terminate_backend"(12345)',
        %(SELECT "nextval"('some_seq')),
        'SELECT "pg_sleep"(10)',
        'SELECT `pg_sleep`(10)'
      ].each do |sql|
        it "does not let #{sql.inspect} bypass the allowlist" do
          expect { validator.validate!(sql) }
            .to raise_error(Woods::Console::SqlValidationError, /allowlist/i)
        end
      end
    end

    context 'with backend-agnostic read functions' do
      [
        'group_concat(name)', 'string_agg(name, \',\')', 'array_agg(name)',
        "json_extract(data, '$.x')", "strftime('%Y', created_at)",
        'row_number() OVER ()', 'rank() OVER (ORDER BY amount)',
        'replace(name, \'a\', \'b\')', 'left(name, 3)'
      ].each do |expr|
        it "accepts #{expr}" do
          expect { validator.validate!("SELECT #{expr} FROM orders") }.not_to raise_error
        end
      end
    end

    context 'with SQL keywords that use parentheses but are not function calls' do
      it 'does not misclassify IN (subquery) as a function call' do
        expect { validator.validate!('SELECT * FROM users WHERE id IN (SELECT user_id FROM posts)') }
          .not_to raise_error
      end

      it 'does not misclassify a grouped boolean expression as a function call' do
        expect { validator.validate!('SELECT * FROM users WHERE (active = true)') }.not_to raise_error
      end
    end
  end
end
