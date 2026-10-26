# frozen_string_literal: true

# Elapsed-time budgets for the complexity specs. Shared CI runners and parallel
# rspec processes make wall-clock time noisy, so a budget fails only where the
# timing is meant to be stable: the performance workflow, or a local run with
# WOODS_RUN_PERF_SPECS set. Everywhere else the block still runs, and an
# overrun is reported on stderr instead of failing. Each spec's Regexp.timeout
# (or Timeout) guard still fails a backtracking pattern in every lane.
module WallClockBudget
  # @return [Boolean] whether elapsed-time budgets are asserted in this run
  def self.enforced?
    !ENV['WOODS_RUN_PERF_SPECS'].nil?
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
    if WallClockBudget.enforced?
      expect(elapsed).to be < budget
    elsif elapsed >= budget
      warn "wall-clock budget exceeded: #{elapsed.round(2)}s over #{budget}s (enforced only with WOODS_RUN_PERF_SPECS)"
    end
  end
end
