# frozen_string_literal: true

require 'spec_helper'
require 'set'
require 'timeout'
require 'woods/extractors/helper_call_scan'
require 'woods/extractors/view_engines/erb'
require 'woods/extractors/view_engines/haml'
require 'woods/extractors/view_engines/jbuilder'

# Template and class source is uncontrolled input. The helper call scan and
# each engine's Ruby-region pass must stay linear on adversarial text. Ruby
# 3.2+ memoizes regexp backtracking, which hides most polynomial patterns;
# the Ruby 3.0/3.1 rows are the ones that catch a regression, through the
# Timeout fallback.
RSpec.describe 'Helper call scan complexity' do
  include WallClockBudget

  budget_seconds = 1.0
  spaces = ' ' * 50_000
  names = Set.new(%w[pretty_date widget_badge title staff?])

  adversarial_sources = {
    'a name then spaces' => "title#{spaces}",
    'a name, spaces, then an assignment' => "title#{spaces}= 1",
    'repeated calls' => 'pretty_date ' * 10_000,
    'near-miss names' => 'pretty_dat ' * 10_000,
    'near-miss longer names' => 'pretty_datex ' * 10_000,
    'one long identifier' => 'a' * 50_000,
    'repeated predicates' => 'staff? ' * 10_000,
    'repeated helpers proxies' => 'helpers.' * 20_000,
    'repeated dots' => '.' * 50_000,
    'repeated colons' => ':' * 50_000,
    'repeated at signs' => '@' * 50_000,
    'repeated number dots' => '1.' * 25_000,
    'repeated single quotes' => "'" * 50_001,
    'escaped quote storm' => "'\\" * 25_000,
    'escaped quote storm across lines' => "'\\\n" * 20_000,
    'repeated double quotes' => '"' * 50_001,
    'repeated interpolation openers in a string' => "\"#{'#{' * 25_000}",
    'nested strings in interpolations' => '"#{' * 20_000,
    'repeated word-array openers' => '%w[' * 20_000,
    'repeated block openers' => '{|' * 25_000,
    'repeated do-pipe openers' => 'do |a ' * 10_000,
    'do-pipe then a long line' => "do |#{'a' * 50_000}",
    'repeated local_assigns probes' => 'local_assigns[' * 10_000,
    'local_assigns then spaces' => "local_assigns.fetch(#{spaces}",
    'repeated defined? probes' => 'defined?(' * 10_000,
    'defined? then spaces' => "defined?#{spaces}",
    'repeated heredoc openers on one line' => '<<~A ' * 10_000,
    'repeated heredoc openers across lines' => "<<~A\n" * 10_000,
    'heredoc then spaces on every line' => "<<~A\n#{"#{' ' * 500}x\n" * 100}",
    'non-ASCII text' => 'é title ' * 10_000,
    'repeated ERB openers' => '<%' * 25_000,
    'repeated ERB output tags' => '<%= ' * 10_000,
    'repeated ERB comment openers' => '<%#' * 10_000,
    'repeated literal ERB openers' => '<%%' * 20_000,
    'strict locals then a long list' => "<%# locals: (#{'a:' * 25_000}",
    'repeated strict-locals comments' => '<%# locals: (a:) %>' * 5_000,
    'repeated HAML attribute openers' => '%a{' * 20_000,
    'HAML attribute opener on every line' => "%a{\n" * 20_000,
    'HAML html attributes then names' => "%a(#{'x=' * 25_000}",
    'HAML html attributes then a long word' => "%a(#{'x' * 50_000}",
    'repeated HAML object references' => '%a[' * 20_000,
    'repeated HAML class segments' => '.a' * 25_000,
    'repeated percent signs' => '%' * 50_000,
    'HAML comma continuations' => "= a,\n" * 20_000,
    'repeated interpolation openers in text' => '#{' * 25_000,
    'non-ASCII interpolations' => "é\#{a} " * 10_000,
    'one long non-ASCII interpolation line' => "#{'é' * 25_000}\#{title}#{'é' * 25_000}",
    'HAML tag trim markers' => "%a#{'<>' * 25_000}",
    'filter body of interpolation openers' => ":javascript\n#{"  \#{\n" * 20_000}"
  }

  scans = {
    'token scan' => ->(source) { Woods::Extractors::HelperCallScan.method_calls(source, names) },
    'erb' => ->(source) { Woods::Extractors::ViewEngines::Erb.new.scan_method_calls(source, names) },
    'haml' => ->(source) { Woods::Extractors::ViewEngines::Haml.new.scan_method_calls(source, names) },
    'jbuilder' => ->(source) { Woods::Extractors::ViewEngines::Jbuilder.new.scan_method_calls(source, names) }
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

  scans.each do |scan_name, scan|
    adversarial_sources.each do |label, source|
      it "#{scan_name} stays within #{budget_seconds}s on #{label}" do
        within_budget(budget_seconds) { scan.call(source) }
      end
    end
  end
end
