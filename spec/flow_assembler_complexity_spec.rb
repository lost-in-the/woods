# frozen_string_literal: true

require 'spec_helper'
require 'timeout'
require 'woods/flow_assembler'

# Call targets come from uncontrolled source. The receiver gate must stay
# linear on adversarial text. Ruby 3.2+ memoizes regexp backtracking, which
# hides most polynomial patterns; the Ruby 3.0/3.1 rows catch a regression
# through the Timeout fallback.
RSpec.describe 'Flow assembler receiver gate complexity' do
  budget_seconds = 1.0

  adversarial_targets = {
    'a long constant ending in a bad character' => "#{'A' * 50_000}!",
    'a long chain ending in a lowercase segment' => "#{'A::' * 16_000}a",
    'a long chain ending in a dangling separator' => "#{'Aa' * 10_000}::",
    'repeated near-matches broken by a single colon' => 'Aa:' * 10_000,
    'a long chain of digits and underscores' => "A#{'_1' * 25_000}::"
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

  adversarial_targets.each do |label, target|
    it "rejects #{label} in linear time" do
      expect(target.match?(Woods::FlowAssembler::CONSTANT_RECEIVER)).to be(false)
    end
  end
end
