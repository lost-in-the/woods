# frozen_string_literal: true

require 'spec_helper'
require 'timeout'
require 'active_support/core_ext/string/inflections'
require 'woods/extractors/migration_extractor'

# Migration source is uncontrolled input. The table-name scans must stay
# linear on adversarial text. Ruby 3.2+ memoizes regexp backtracking, which
# hides most polynomial patterns; the Ruby 3.0/3.1 rows catch a regression
# through the Timeout fallback.
RSpec.describe 'Migration table scan complexity' do
  include_context 'extractor setup'

  budget_seconds = 1.0
  repeats = 50_000
  near_matches = 10_000

  around do |example|
    if Regexp.respond_to?(:timeout=)
      previous = Regexp.timeout
      Regexp.timeout = budget_seconds
      begin
        example.run
      ensure
        Regexp.timeout = previous
      end
    else
      Timeout.timeout(budget_seconds * 5) { example.run }
    end
  end

  let(:extractor) do
    Woods::Extractors::MigrationExtractor.new(table_catalog: Woods::Extractors::TableCatalog.new([]))
  end

  def within_budget(budget)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    yield
    expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < budget
  end

  {
    'an operation followed by a long whitespace run' => "add_column#{' ' * repeats}",
    'an operation, an open paren, then a long whitespace run' => "create_table(#{' ' * repeats}",
    'a long table name with no closing quote' => "add_column \"#{'a' * repeats}",
    'repeated operations with no table' => 'add_index ' * near_matches,
    'repeated operations that stop before the name' => 'create_table(: ' * near_matches,
    'a foreign key with a long gap before the comma' => "add_foreign_key :widgets#{' ' * repeats}x",
    'a foreign key with a long first name' => "add_foreign_key :#{'a' * repeats} :",
    'repeated foreign keys missing the second table' => 'add_foreign_key :widgets, ' * near_matches,
    'a to_table option followed by a long whitespace run' => "to_table:#{' ' * repeats}",
    'repeated to_table options with no value' => 'to_table: ' * near_matches,
    'a join table with a long gap before the comma' => "create_join_table :widgets#{' ' * repeats}x",
    'repeated join tables missing the second table' => 'create_join_table :widgets, ' * near_matches,
    'a long run of quotes' => "add_column #{'"' * repeats}"
  }.each do |label, source|
    it "stays within #{budget_seconds}s on #{label}" do
      within_budget(budget_seconds) do
        extractor.send(:extract_tables_affected, source)
        extractor.send(:extract_tables_referenced, source, [])
      end
    end
  end
end
