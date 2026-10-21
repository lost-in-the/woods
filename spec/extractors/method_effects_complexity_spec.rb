# frozen_string_literal: true

require 'spec_helper'
require 'timeout'
require 'woods'
require 'woods/extracted_unit'
require 'woods/extractors/method_effects'

# Method bodies are uncontrolled source, and every method of a unit's class
# is scanned, not only its callbacks. Each scan must stay linear on
# adversarial text. Ruby 3.2+ memoizes regexp backtracking, which hides most
# polynomial patterns; the Ruby 3.0/3.1 rows catch a regression through the
# Timeout fallback.
#
# The structural cases (many methods, many reopenings) are sized so that the
# parse they need stays a small share of the budget: the walk over the
# parsed methods is what they measure.
RSpec.describe 'Method effects complexity' do
  budget_seconds = 1.0
  spaces = ' ' * 50_000

  def self.in_method(body)
    "class Ledger\n  def post\n#{body}\n    SentinelJob.perform_later\n  end\nend\n"
  end

  every_call = (1..100).map { |m| "    m#{m}\n" }.join
  fan_out = (1..100).map { |n| "  def m#{n}\n#{every_call}    Step#{n}Job.perform_later\n  end\n" }
  chain = (1..1_000).map { |n| "  def m#{n}\n    m#{n + 1}\n    Step#{n}Job.perform_later\n  end\n" }

  adversarial_sources = {
    'self. then a long word' => in_method("self.#{'a' * 50_000}"),
    'self.column then spaces' => in_method("self.status#{spaces}"),
    'repeated self assignments' => in_method("self.status = 1\n" * 10_000),
    'repeated near-assignments' => in_method("self.status == 1\n" * 10_000),
    'update_column then spaces' => in_method("update_column#{spaces}"),
    # A word array survives neutralization, so its text reaches the scans
    # with parens that never close.
    'repeated unclosed update_columns calls' => in_method("words = %w[#{'update_columns( ' * 10_000}]"),
    'an unclosed update_columns with many keys' => in_method("words = %w[update_columns( #{'status: ' * 50_000}]"),
    'repeated unclosed assign_attributes calls' => in_method("words = %w[#{"assign_attributes(\n" * 10_000}]"),
    'unclosed update_columns calls before a late paren' =>
      in_method("words = %w[#{'update_columns( ' * 10_000}]\ntouch()"),
    'a long word ending in Service' => in_method("#{'a' * 50_000}Service"),
    'a chain of segments ending in Service' => in_method("#{'A::' * 16_000}Service.call"),
    'a chain that breaks before Job.perform_later' => in_method("#{'A::JobA' * 7_000} Job.perform_later"),
    'repeated enqueues' => in_method("PostJob.perform_later\n" * 10_000),
    'repeated near-enqueues' => in_method("PostJob.perform_latex\n" * 10_000),
    'repeated instrument calls' => in_method("ActiveSupport::Notifications.instrument('a.b')\n" * 10_000),
    'repeated HTTP calls' => in_method("Faraday.get(url)\n" * 10_000),
    'repeated same-class calls' => in_method("post\nother\n" * 25_000),
    'ten thousand lines of ordinary words' => in_method("aa bb cc dd ee ff gg hh\n" * 10_000),
    'two thousand empty methods' => "class Ledger\n#{"  def quiet; end\n" * 2_000}end\n",
    'five thousand visibility modifiers' => "class Ledger\n  def post; end\n#{"  private :post\n" * 5_000}end\n",
    'a class reopened five hundred times' => "class Ledger\n  def post\n    PostJob.perform_later\n  end\nend\n" * 500,
    'every method calling every other' => "class Ledger\n#{fan_out.join}end\n",
    'a thousand method call chain' => "class Ledger\n#{chain.join}end\n"
  }

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

  adversarial_sources.each do |label, source|
    it "stays within budget on #{label}" do
      logger = double('logger', warn: nil)
      stub_const('Rails', double('Rails', logger: logger))
      unit = Woods::ExtractedUnit.new(type: :model, identifier: 'Ledger', file_path: 'app/models/ledger.rb')
      unit.metadata = {}
      unit.dependencies = [
        { type: :job, target: 'PostJob', via: :job_enqueue },
        { type: :job, target: 'SentinelJob', via: :job_enqueue }
      ]
      source_with_sentinel = <<~RUBY
        #{source}
        class Ledger
          def woods_effects_sentinel
            SentinelJob.perform_later
          end
        end
      RUBY

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      Woods::Extractors::MethodEffects.apply(unit, source_with_sentinel, column_names: %w[status], limit: 50)
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      expect(elapsed).to be < budget_seconds * 5
      expect(logger).not_to have_received(:warn)
      expect(unit.dependencies.last[:through].to_s.split(', ')).to include('woods_effects_sentinel')
      if source.include?('SentinelJob.perform_later')
        expect(unit.metadata.dig(:method_effects, 'post', :jobs_enqueued)).to include('SentinelJob')
      end
    end
  end
end
