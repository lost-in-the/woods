# frozen_string_literal: true

# Benchmark: Woods::Console::SqlValidator
#
# What this measures:
#   SqlValidator#validate! is called once per console_sql tool invocation —
#   the hot path is a clean SELECT that passes all checks. The bench also
#   covers rejection paths so we can see the relative cost of each guard.
#
#   1. Simple SELECT (passes all checks) — the common case; measures the
#      full validation pipeline on a minimal clean query.
#   2. Complex SELECT with CTEs and subqueries — a realistic analytics query
#      a developer might send; exercises the multi-check pipeline on a longer
#      string.
#   3. Forbidden prefix rejection (INSERT) — hits check_forbidden_keywords!
#      on the first check and raises immediately.
#   4. Body keyword rejection (UNION) — passes the prefix check, then hits
#      check_body_forbidden_keywords!.
#   5. Comment-hidden keyword (SELECT --; DELETE) — exercises the
#      check_forbidden_keywords_in_body! strip-then-scan path.
#
# How to run:
#   bundle exec ruby bench/sql_validator_bench.rb
#
# What "good" looks like:
#   - Simple SELECT:   > 100_000 i/s  (frozen constants + fast match? exit)
#   - Complex SELECT:  > 30_000 i/s   (TODO: calibrate)
#   - Rejections:      roughly comparable to their passing counterparts —
#                      early exits should be faster than full-pass validation
#
# Note: benchmark-ips must be installed (it is a dev dependency of this gem).
# These benchmarks are NOT part of the test suite and are never run in CI.

require 'bundler/setup'
require 'benchmark/ips'

require_relative '../lib/woods/console/sql_validator'

validator = Woods::Console::SqlValidator.new

# ── Inputs ───────────────────────────────────────────────────────────────────

SIMPLE_SELECT = 'SELECT id, email, created_at FROM users WHERE id = 42'.freeze

COMPLEX_SELECT = <<~SQL.freeze
  WITH recent_orders AS (
    SELECT user_id, COUNT(*) AS order_count, SUM(total_cents) AS total
    FROM orders
    WHERE created_at > NOW() - INTERVAL '30 days'
    GROUP BY user_id
  ),
  high_value AS (
    SELECT user_id FROM recent_orders WHERE total > 10000
  )
  SELECT u.id, u.email, ro.order_count, ro.total
  FROM users u
  JOIN recent_orders ro ON ro.user_id = u.id
  WHERE u.id IN (SELECT user_id FROM high_value)
  ORDER BY ro.total DESC
  LIMIT 100
SQL

INSERT_SQL = 'INSERT INTO users (email) VALUES (\'attacker@evil.com\')'.freeze

UNION_SQL = 'SELECT id FROM users UNION SELECT id FROM admins'.freeze

COMMENT_HIDDEN_SQL = "SELECT 1 --;\nDELETE FROM users".freeze

Benchmark.ips do |x|
  x.config(warmup: 2, time: 5)

  x.report('simple SELECT (passes)') do
    validator.validate!(SIMPLE_SELECT)
  rescue Woods::Console::SqlValidationError
    nil
  end

  x.report('complex SELECT with CTEs (passes)') do
    validator.validate!(COMPLEX_SELECT)
  rescue Woods::Console::SqlValidationError
    nil
  end

  x.report('INSERT rejection (prefix check)') do
    validator.validate!(INSERT_SQL)
  rescue Woods::Console::SqlValidationError
    nil
  end

  x.report('UNION rejection (body keyword check)') do
    validator.validate!(UNION_SQL)
  rescue Woods::Console::SqlValidationError
    nil
  end

  x.report('comment-hidden DELETE rejection') do
    validator.validate!(COMMENT_HIDDEN_SQL)
  rescue Woods::Console::SqlValidationError
    nil
  end

  x.compare!
end
