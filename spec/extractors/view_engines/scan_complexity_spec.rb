# frozen_string_literal: true

require 'spec_helper'
require 'timeout'
require 'woods/extractors/view_engines/erb'
require 'woods/extractors/view_engines/haml'
require 'woods/extractors/view_engines/jbuilder'

# Template source is uncontrolled input. Every engine scan must stay linear
# on adversarial text, so a polynomial pattern fails here instead of
# stalling an extraction. Ruby 3.2+ memoizes regexp backtracking, which hides
# most polynomial patterns; the Ruby 3.0/3.1 rows are the ones that catch a
# regression, through the Timeout fallback.
RSpec.describe 'View engine scan complexity' do
  budget_seconds = 1.0
  spaces = ' ' * 50_000

  adversarial_sources = {
    'json.partial! then spaces' => "json.partial!#{spaces}",
    'json.partial!( then spaces' => "json.partial!(#{spaces}",
    'json call then spaces' => "json.widgets#{spaces}",
    'json call then a long word' => "json.#{'a' * 50_000}",
    'repeated json calls' => 'json.widgets ' * 10_000,
    'json.partial! then a long expression chain' => "json.partial! #{'a.' * 25_000}",
    'comma continuations' => "json.widgets,#{" ,\n" * 20_000}",
    'render then spaces' => "= render#{spaces}",
    'render( then spaces' => "= render(#{spaces}",
    'repeated render calls' => '= render ' * 10_000,
    'form_with then spaces' => "= form_with#{spaces}",
    'repeated form_with calls' => '= form_with ' * 10_000,
    'filter interpolation then spaces' => ":javascript\n  \#{#{spaces}",
    'ERB form_with then spaces' => "<%= form_with#{spaces}",
    'ERB form_with then a long word' => "<%= form_with #{'a' * 50_000}",
    'ERB form_with then underscored words' => "<%= form_with #{'a_' * 25_000}",
    'ERB repeated form_with calls' => '<%= form_with ' * 10_000,
    'ERB render then spaces' => "<%= render#{spaces}",
    'ERB repeated render calls' => '<%= render ' * 10_000
  }

  engines = [Woods::Extractors::ViewEngines::Erb.new, Woods::Extractors::ViewEngines::Haml.new,
             Woods::Extractors::ViewEngines::Jbuilder.new]
  scans = %i[scan_partials scan_unresolved_partials scan_helpers scan_navigation_candidates]

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

  engines.each do |engine|
    adversarial_sources.each do |label, source|
      it "#{engine.name} scans stay within #{budget_seconds}s on #{label}" do
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        scans.each { |scan| engine.public_send(scan, source) }
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
        expect(elapsed).to be < budget_seconds
      end
    end
  end
end
