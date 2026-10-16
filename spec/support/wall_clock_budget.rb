# frozen_string_literal: true

# Elapsed-time budgets for the complexity specs. Coverage instrumentation
# slows the Ruby around each scan, so under COVERAGE a budget measures the
# instrumentation; each spec's Regexp.timeout (or Timeout) guard still fails a
# backtracking pattern in every lane. WOODS_RUN_PERF_SPECS restores the budget.
module WallClockBudget
  # @return [Boolean] whether elapsed-time budgets are asserted in this run
  def self.enforced?
    !ENV['COVERAGE'] || !ENV['WOODS_RUN_PERF_SPECS'].nil?
  end

  # Runs the block, then expects it to have finished within +budget+ seconds.
  #
  # @param budget [Numeric] seconds
  def within_budget(budget)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    yield
    expect_elapsed_within(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, budget)
  end

  # @param elapsed [Numeric] seconds measured elsewhere (a child process)
  # @param budget [Numeric] seconds
  def expect_elapsed_within(elapsed, budget)
    expect(elapsed).to be < budget if WallClockBudget.enforced?
  end
end
