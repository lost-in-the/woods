# frozen_string_literal: true

require 'spec_helper'
require 'timeout'
require 'woods/extractors/scheduled_job_extractor'

# Cron lines, durations and schedule sources are uncontrolled input. Every
# pattern the schedule readers apply must stay linear on adversarial text.
# Ruby 3.2+ memoizes regexp backtracking, which hides most polynomial
# patterns; the Ruby 3.0/3.1 rows catch a regression through the Timeout
# fallback.
RSpec.describe 'Scheduled job scan complexity' do
  include_context 'extractor setup'

  budget_seconds = 1.0
  zeros = '0' * 50_000
  letters = 'a' * 50_000

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

  def within_budget(budget)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    yield
    expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < budget
  end

  {
    'a long digit run' => zeros,
    'a long digit run then a letter outside the unit class' => "#{zeros}x",
    'a long digit run then a unit' => "#{zeros}m",
    'a long digit run, a letter outside the unit class, then a unit' => "#{zeros}xm",
    'a long digit run, a space, then a unit' => "#{zeros} m",
    'repeated near-match durations' => '1x' * 10_000,
    'repeated durations then a bad tail' => "#{'1m' * 10_000}1x",
    'a long word' => letters
  }.each do |label, value|
    it "CronHumanizer.every stays within #{budget_seconds}s on #{label}" do
      within_budget(budget_seconds) { Woods::Extractors::CronHumanizer.every(value) }
    end
  end

  {
    'a long digit run' => zeros,
    'a long digit run then a letter' => "#{zeros}x",
    'a stepped field with a long digit run' => "*/#{zeros}",
    'a stepped field with a long digit run then a letter' => "*/#{zeros}x * * * *",
    'six fields ending in a long zone-like word' => "0 0 * * * #{letters}/#{letters}!",
    'six fields ending in repeated zone segments' => "0 0 * * * A#{'/b' * 10_000}!",
    'a seconds step with a long digit run' => "*/#{zeros}x * * * * *",
    'repeated near-match fields' => '1-' * 10_000,
    'many fields' => '* ' * 10_000
  }.each do |label, value|
    it "CronHumanizer.humanize stays within #{budget_seconds}s on #{label}" do
      within_budget(budget_seconds) { Woods::Extractors::CronHumanizer.humanize(value) }
    end
  end

  {
    'an unclosed quote' => "'#{letters}",
    'a closed quote then a long tail' => "'0 7 * * *'#{letters}",
    'repeated quotes' => "'a" * 10_000
  }.each do |label, frequency|
    it "the Whenever frequency describer stays within #{budget_seconds}s on #{label}" do
      extractor = Woods::Extractors::ScheduledJobExtractor.new
      within_budget(budget_seconds) { extractor.send(:humanize_whenever_frequency, frequency) }
    end
  end

  {
    'a long identifier' => letters,
    'repeated near-misses of every hint' => 'periodi Cron::Jo schedul ' * 10_000
  }.each do |label, source|
    it "the Ruby source hint stays within #{budget_seconds}s on #{label}" do
      hint = Woods::Extractors::ScheduledJobExtractor::RUBY_SCHEDULE_HINT
      within_budget(budget_seconds) { hint.match?(source) }
    end
  end

  {
    'a long constant-like name' => "Ledger#{letters}",
    'repeated namespace segments then a bad tail' => "#{'Ledger::' * 10_000}!",
    'a long digit-led name' => zeros
  }.each do |label, name|
    it "class inference stays within #{budget_seconds}s on #{label}" do
      extractor = Woods::Extractors::ScheduledJobExtractor.new
      within_budget(budget_seconds) do
        extractor.send(:infer_scheduler_class, { name: name, job_class: nil, options: {} })
      end
    end
  end
end
