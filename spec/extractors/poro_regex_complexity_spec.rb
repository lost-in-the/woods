# frozen_string_literal: true

require 'spec_helper'
require 'timeout'
require 'woods/extractors/poro_extractor'

# Ruby 3.2+ memoizes backtracking, which hides polynomial patterns; the
# timeout still catches them, and Ruby < 3.2 runs under a wall-clock budget.
RSpec.describe Woods::Extractors::PoroExtractor, 'regex complexity' do
  def within_budget(&block)
    if Regexp.respond_to?(:timeout=)
      previous = Regexp.timeout
      Regexp.timeout = 1.0
      begin
        block.call
      ensure
        Regexp.timeout = previous
      end
    else
      Timeout.timeout(5, &block)
    end
  end

  it 'finds an own method definition in linear time over blank lines and near misses' do
    pattern = described_class::OWN_METHOD_DEFINITION
    within_budget do
      expect(pattern.match?("\n" * 50_000)).to be(false)
      expect(pattern.match?(" \t\n" * 50_000)).to be(false)
      expect(pattern.match?("  de\n" * 10_000)).to be(false)
      # A literal `def` defeats the engine's substring prefilter; on Ruby 3.0 the
      # old /^\s*def\s/ spent 11.9s on the first input and 3.7s on the second.
      expect(pattern.match?("#{"\n" * 50_000}x def ")).to be(false)
      expect(pattern.match?("#{" \n" * 20_000}defx")).to be(false)
      expect(pattern.match?("#{"\n" * 50_000}  def call")).to be(true)
    end
  end

  it 'counts declaration lines and finds value-class factories in linear time' do
    lines = described_class::DECLARATION_LINE
    factories = described_class::VALUE_CLASS_CONSTRUCTOR
    within_budget do
      expect("#{" \t" * 50_000}classy".scan(lines)).to eq([])
      expect(("  clas\n" * 10_000).scan(lines)).to eq([])
      expect(("  module X\n" * 10_000).scan(lines).size).to eq(10_000)
      expect(factories.match?('Struct.ne' * 50_000)).to be(false)
      expect(factories.match?("#{'Data.' * 50_000}define")).to be(true)
    end
  end

  it 'captures declaration tokens and recognizes constant paths in linear time' do
    lines = described_class::DECLARATION_LINE
    path = described_class::CONSTANT_PATH
    within_budget do
      expect("class #{'A' * 50_000}".scan(lines).flatten.first.size).to eq(50_000)
      expect(path.match?("#{'A::' * 25_000}A")).to be(true)
      expect(path.match?("#{'A::' * 25_000}a!")).to be(false)
      expect(path.match?("A#{'b' * 50_000}:")).to be(false)
    end
  end

  it 'strips the app directory prefix in linear time' do
    pattern = described_class::APP_DIRECTORY_PREFIX
    within_budget do
      expect(pattern.match?("app/#{'x' * 50_000}")).to be(false)
      expect(pattern.match?("app/#{'x' * 10}/\n" * 10_000)).to be(true)
      expect(pattern.match?("lib\napp/#{'x' * 10}/")).to be(false)
    end
  end
end
