# frozen_string_literal: true

require 'spec_helper'
require 'timeout'
require 'woods'
require 'woods/extractors/shared_dependency_scanner'

# Source handed to the shared dependency scans is uncontrolled. Each scan
# must stay linear on adversarial text. Ruby 3.2+ memoizes regexp
# backtracking, which hides most polynomial patterns; the Ruby 3.0/3.1 rows
# catch a regression through the Timeout fallback.
RSpec.describe 'Shared dependency scan complexity' do
  budget_seconds = 1.0
  spaces = ' ' * 50_000

  adversarial_sources = {
    'form_with then spaces' => "form_with#{spaces}",
    'form_with then a long word' => "form_with #{'a' * 50_000}",
    'form_with then underscored words' => "form_with #{'a_' * 25_000}",
    'repeated form_with calls' => 'form_with ' * 10_000,
    'a long word ending in Service' => "#{'a' * 50_000}Service",
    'a long word ending in Job' => "#{'a' * 50_000}Job",
    'repeated words ending in Service' => 'aService' * 6_000,
    'a chain of segments ending in Service' => "#{'A::' * 16_000}Service",
    'a chain that breaks before Mailer.' => "#{'A::MailerA' * 5_000} Mailer.",
    'a chain that breaks before Service.' => "#{'A::ServiceA' * 5_000} Service.",
    'a chain that breaks before Job.perform_later' => "#{'A::JobA' * 7_000} Job.perform_later",
    'repeated enqueues running into the next word' => 'AJob.perform_later' * 3_000,
    # Not backtracking: the reference loop used to read character offsets
    # from MatchData, which counts from the start of the string on every
    # call, so ordinary text took time quadratic in its size.
    'fifty thousand lines of ordinary words' => "aa bb cc dd ee ff gg hh\n" * 50_000
  }

  let(:scanner) do
    Class.new do
      include Woods::Extractors::SharedDependencyScanner
      include Woods::Extractors::RouteHelperResolver

      def initialize
        @route_helper_map = {}
      end
    end.new
  end

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

  before do
    Woods.configure unless Woods.configuration
    allow(Woods.configuration).to receive(:extract_navigation_edges).and_return(true)
  end

  adversarial_sources.each do |label, source|
    it "service, job, mailer, and form scans stay within #{budget_seconds}s on #{label}" do
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      scanner.scan_service_dependencies(source)
      scanner.scan_job_dependencies(source)
      scanner.scan_mailer_dependencies(source)
      scanner.scan_form_dependencies(source)
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      expect(elapsed).to be < budget_seconds
    end
  end
end
