# frozen_string_literal: true

# Benchmark: Woods::Console::CredentialScanner
#
# What this measures:
#   CredentialScanner#scan is called on every Console MCP tool response —
#   once per response string/hash/array value. This bench covers the four
#   input shapes the scanner sees in practice:
#
#   1. Short clean string     — a typical scalar column value with no credential.
#   2. Long clean string      — a large text/blob column with no credential.
#   3. String with a match    — a value that triggers at least one pattern.
#   4. EAV hash (100 rows)    — a console_data_snapshot-style rows payload where
#      each element is { key: <name>, value: <data> }. The hot path in production:
#      the scanner walks the entire hash tree for every page of results.
#
# How to run:
#   bundle exec ruby bench/credential_scanner_bench.rb
#
# What "good" looks like:
#   - Short/long clean strings: > 50_000 i/s  (TODO: calibrate on target hardware)
#   - String with match:        > 20_000 i/s  (pattern gsub triggers once)
#   - EAV hash (100 rows):      > 300 i/s     (TODO: calibrate)
#
# Note: benchmark-ips must be installed (it is a dev dependency of this gem).
# These benchmarks are NOT part of the test suite and are never run in CI.

require 'bundler/setup'
require 'benchmark/ips'

# Load the component under bench without booting Rails.
require_relative '../lib/woods/console/credential_index'
require_relative '../lib/woods/console/credential_scanner'

scanner = Woods::Console::CredentialScanner.new

# ── Inputs ───────────────────────────────────────────────────────────────────

SHORT_CLEAN = 'hello@example.com'.freeze

LONG_CLEAN = ('Lorem ipsum dolor sit amet, consectetur adipiscing elit. ' * 100).freeze

# A Stripe secret key — triggers stripe_secret_key pattern.
STRING_WITH_MATCH = 'payment token: sk_test_4eC39HqLyjWDarjtT1zdp7dc and more text after'.freeze

# Simulate a console_data_snapshot rows payload: 100 rows, each a hash with
# string key column name and a clean string value. Realistic column names
# drawn from a typical ActiveRecord model (no credentials).
EAV_ROWS = Array.new(100) do |i|
  {
    'id'         => (1000 + i).to_s,
    'email'      => "user#{i}@example.com",
    'name'       => "User #{i}",
    'created_at' => "2024-01-#{(i % 28) + 1}",
    'status'     => %w[active inactive pending][i % 3]
  }
end.freeze

Benchmark.ips do |x|
  x.config(warmup: 2, time: 5)

  x.report('short clean string') do
    scanner.scan(SHORT_CLEAN)
  end

  x.report('long clean string (5.5KB)') do
    scanner.scan(LONG_CLEAN)
  end

  x.report('string with Stripe key match') do
    scanner.scan(STRING_WITH_MATCH)
  end

  x.report('EAV hash 100 rows (5 columns each)') do
    scanner.scan(EAV_ROWS)
  end

  x.compare!
end
