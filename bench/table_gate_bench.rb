# frozen_string_literal: true

# Benchmark: Woods::Console::TableGate
#
# What this measures:
#   TableGate is called on every console_sql, console_query, console_joins,
#   and console_association_count invocation. The gate's hot path is a clean
#   query that touches no blocked tables. The bench covers:
#
#   1. check_sql! — simple SELECT, no blocked tables — measures strip_noise +
#      regex scan over a short query. The common case.
#   2. check_sql! — complex multi-join SELECT, no blocked tables — exercises
#      the FROM_CLAUSE + JOIN_REFERENCE scan over a longer string.
#   3. check_sql! — query that hits a blocked table — measures how quickly
#      the gate raises TableGateError.
#   4. check_model! — model name lookup (hash read + check_table!) — fast
#      path for model-based tools.
#   5. check_joins! — resolves two association names through the reflection
#      map — the console_query joins path.
#   6. inactive gate (no blocked tables) — TableGate#active? short-circuit —
#      should be near-zero overhead.
#
# How to run:
#   bundle exec ruby bench/table_gate_bench.rb
#
# What "good" looks like:
#   - Simple SQL, no match:    > 20_000 i/s  (strip_noise + scan on short string)
#   - Complex SQL, no match:   > 5_000 i/s   (TODO: calibrate)
#   - check_model!:            > 200_000 i/s (hash lookup only)
#   - Inactive gate:           > 1_000_000 i/s (single boolean check)
#
# Note: benchmark-ips must be installed (it is a dev dependency of this gem).
# These benchmarks are NOT part of the test suite and are never run in CI.

require 'bundler/setup'
require 'benchmark/ips'

require_relative '../lib/woods/console/table_gate'

# ── Gate configurations ───────────────────────────────────────────────────────

MODEL_TABLES = {
  'User'          => 'users',
  'Order'         => 'orders',
  'Product'       => 'products',
  'Authorization' => 'authorizations',
  'AuditLog'      => 'audit_logs'
}.freeze

MODEL_REFLECTIONS = {
  'User' => {
    'orders'         => 'orders',
    'authorizations' => 'authorizations',
    'audit_logs'     => 'audit_logs'
  },
  'Order' => {
    'user'     => 'users',
    'products' => 'products'
  }
}.freeze

# Active gate: authorizations and audit_logs are blocked.
ACTIVE_GATE = Woods::Console::TableGate.new(
  blocked_tables:    %w[authorizations audit_logs],
  model_tables:      MODEL_TABLES,
  model_reflections: MODEL_REFLECTIONS
)

# Inactive gate: no blocked tables — represents an unconfigured or opt-out host.
INACTIVE_GATE = Woods::Console::TableGate.new(
  blocked_tables:    [],
  model_tables:      MODEL_TABLES,
  model_reflections: MODEL_REFLECTIONS
)

# ── SQL inputs ────────────────────────────────────────────────────────────────

SIMPLE_SQL = 'SELECT id, email FROM users WHERE status = \'active\''.freeze

COMPLEX_SQL = <<~SQL.freeze
  SELECT u.id, u.email, o.id AS order_id, o.total_cents, p.name AS product_name
  FROM users u
  JOIN orders o ON o.user_id = u.id
  JOIN order_items oi ON oi.order_id = o.id
  JOIN products p ON p.id = oi.product_id
  WHERE u.created_at > '2024-01-01'
    AND o.status = 'completed'
  ORDER BY o.created_at DESC
  LIMIT 50
SQL

BLOCKED_SQL = 'SELECT * FROM authorizations WHERE user_id = 1'.freeze

Benchmark.ips do |x|
  x.config(warmup: 2, time: 5)

  x.report('check_sql! simple SELECT (no blocked table)') do
    ACTIVE_GATE.check_sql!(SIMPLE_SQL)
  rescue Woods::Console::TableGateError
    nil
  end

  x.report('check_sql! complex multi-join SELECT (no blocked table)') do
    ACTIVE_GATE.check_sql!(COMPLEX_SQL)
  rescue Woods::Console::TableGateError
    nil
  end

  x.report('check_sql! hits blocked table (raises)') do
    ACTIVE_GATE.check_sql!(BLOCKED_SQL)
  rescue Woods::Console::TableGateError
    nil
  end

  x.report('check_model! clean model (hash lookup)') do
    ACTIVE_GATE.check_model!('User')
  rescue Woods::Console::TableGateError
    nil
  end

  x.report('check_joins! two associations (one blocked)') do
    ACTIVE_GATE.check_joins!('User', %w[orders authorizations])
  rescue Woods::Console::TableGateError
    nil
  end

  x.report('inactive gate — check_sql! short-circuit') do
    INACTIVE_GATE.check_sql!(SIMPLE_SQL)
  rescue Woods::Console::TableGateError
    nil
  end

  x.compare!
end
