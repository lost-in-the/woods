# frozen_string_literal: true

require 'spec_helper'
require 'timeout'
require 'woods'
require 'woods/extractors/js_module_facts'
require 'woods/extractors/frontend_references'

# JavaScript, templates and component source are uncontrolled input. Every
# pattern the js_module tokenizer, the facts pass and the frontend reference
# scanner apply must stay linear on adversarial text. Ruby 3.2+ memoizes
# regexp backtracking, which hides most polynomial patterns; the Ruby 3.0/3.1
# rows catch a regression through the Timeout fallback.
RSpec.describe 'JavaScript scan complexity' do
  budget_seconds = 1.0
  repeats = 50_000
  near = 10_000

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

  javascript = {
    'a long identifier' => 'a' * repeats,
    'a long whitespace run' => "#{' ' * repeats}x",
    'unterminated block comments' => '/*' * repeats,
    'unterminated line comment' => "//#{'/' * repeats}",
    'an unterminated double-quoted string' => "\"#{'a\\' * repeats}",
    'an unterminated single-quoted string' => "'#{'\\\\' * repeats}",
    'alternating unterminated quotes on one line' => %('") * repeats,
    'unterminated nested templates' => '`${' * repeats,
    'an unterminated template of dollars' => "`#{'$' * repeats}",
    'template interpolations that never close' => '`${`' * near,
    'regex openers with an unclosed class on one line' => '(/[ ' * near,
    'regex openers with escapes on one line' => '(/\\/ ' * near,
    'a regex of escaped slashes' => "= /#{'\\/' * repeats}",
    'slashes after values' => 'a/' * repeats,
    'a run of equals signs' => '=' * repeats,
    'non-ASCII text' => 'é' * repeats,
    'repeated import keywords' => 'import ' * repeats,
    'unterminated import lists' => 'import { a, ' * near,
    'a long import list without from' => "import { #{'a, ' * repeats}",
    'imports without specifiers' => 'import a from ' * near,
    'unterminated export lists' => 'export { a as ' * near,
    'a long export list without a close' => "export { #{'a ' * repeats}",
    'repeated export star' => 'export * as ' * near,
    'nested Stencil decorators' => '@Component({ ' * near,
    'a decorator with a huge options object' => "@Component({ #{'a: 1, ' * repeats}",
    'near-miss registrations' => 'application.register("a", ' * near,
    'near-miss Alpine registrations' => 'Alpine.data("a" ' * near,
    'near-miss window globals' => 'window.a = window.' * near,
    'near-miss element definitions' => 'customElements.define(' * near,
    'a chain of member accesses' => 'a.' * repeats,
    'deeply nested braces' => '{' * repeats
  }

  javascript.each do |label, source|
    it "JsModuleFacts.parse stays within #{budget_seconds}s on #{label}" do
      within_budget(budget_seconds) { Woods::Extractors::JsModuleFacts.parse(source) }
    end
  end

  markup = {
    'a long word' => 'a' * repeats,
    'repeated x-data without a value' => 'x-data ' * repeats,
    'x-data followed by a long whitespace run' => "x-data#{' ' * repeats}",
    'x-data with separators but no value' => 'x-data = ' * near,
    'unterminated x-data values' => %(x-data="a #{"x-data='b " * near}),
    'x-data values in alternating quotes' => %(x-data="a' x-data='b" ) * near,
    'a long x-data value' => %(x-data="#{'a(' * repeats}"),
    'repeated data-controller without a value' => 'data-controller ' * repeats,
    'a data-controller with many names' => %(data-controller="#{'a ' * repeats}"),
    'a data-controller of unterminated ERB tags' => %(data-controller="#{'<% ' * near}"),
    'a data-controller of unterminated interpolations' => %(data_controller: "#{'#{ ' * near}"),
    'near-miss attribute names' => 'xx-data="a" data-controllers="b" ' * near,
    'repeated data hash openers' => 'data: { ' * repeats,
    'data keys without hashes' => 'data: ' * repeats,
    'controller keys outside a data hash' => 'controller: "a", ' * repeats,
    'controller keys inside one data hash' => "data: { #{'controller: "a", ' * near}",
    'controller keys without values in a data hash' => "data: { #{'controller: ' * repeats}",
    'unbalanced closing braces' => '}' * repeats,
    'unbalanced opening braces' => '{' * repeats,
    'repeated tag openers' => '<' * repeats,
    'near-miss tags' => '<a- ' * near,
    'a long dashed tag' => "<x#{'-a' * repeats}",
    'a long dashed tag ending in a word character' => "<x#{'-a' * repeats}_",
    'haml tags after long indentation' => "#{' ' * repeats}%x-a\n" * 3,
    'whitespace-only lines' => "#{' ' * 100}\n" * near,
    'percent signs' => '%' * repeats,
    'repeated register_element without a symbol' => 'register_element ' * near,
    'register_element with a long symbol' => "register_element :#{'a_' * repeats}"
  }

  markup.each do |label, source|
    it "FrontendReferences::Scanner.scan stays within #{budget_seconds}s on #{label}" do
      within_budget(budget_seconds) { Woods::Extractors::FrontendReferences::Scanner.scan(source) }
    end
  end

  # A path is bounded by the filesystem (PATH_MAX), unlike file contents.
  it "JavascriptPaths.source? stays within #{budget_seconds}s on a path of maximum length" do
    path = "app/javascript/#{'a/' * 2_048}x.js"
    within_budget(budget_seconds) { Woods::JavascriptPaths.source?(path) }
  end
end
