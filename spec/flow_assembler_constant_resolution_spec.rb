# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'json'
require 'open3'
require 'rbconfig'
require 'woods/dependency_graph'
require 'woods/extracted_unit'
require 'woods/flow_assembler'

# How the flow assembler names the constant a call target refers to (#967),
# checked against what Ruby itself evaluates.
#
# Each case is a tiny program. Its units are real Ruby: a child Ruby process
# loads them (and any non-unit "gem" constants), runs the caller, and reports
# which constant the call reached, or that Ruby raised NameError. The same
# sources are written as index units, and the assembler must either agree
# with Ruby or report the step as ambiguous. The child also runs
# FlowAssembler.top_level_constants against its own Object, which is what a
# booted precompute publishes.
#
# The assembler is a static approximation. It does not resolve constants
# lexically, and one example below pins the case where it names a unit Ruby
# would not reach.
RSpec.describe Woods::FlowAssembler, 'constant resolution against Ruby' do
  let(:extracted_dir) { Dir.mktmpdir('flow_constant_resolution') }
  let(:graph) { Woods::DependencyGraph.new }

  after { FileUtils.remove_entry(extracted_dir) }

  # @param units [Array<Hash>] `{ id:, type:, source:, in_graph: }` in load order
  # @param caller_id [String] the unit whose `call` makes the reference
  # @param external [String] non-unit Ruby (a gem's constants), loaded first
  # @return [Hash] `resolved` (constant name or nil for NameError) and
  #   `top_level` (the child's FlowAssembler.top_level_constants)
  def ruby_answer(units:, caller_id:, external: '')
    program = <<~RUBY
      require 'json'
      eval(#{external.dump}, TOPLEVEL_BINDING)
      #{units.map { |unit| "eval(#{unit[:source].dump}, TOPLEVEL_BINDING)" }.join("\n")}
      resolved = begin
        Object.const_get(#{caller_id.dump}).new.call.name
      rescue NameError
        nil
      end
      require 'woods/flow_assembler'
      names = JSON.parse(ARGV.fetch(0))
      puts JSON.generate('resolved' => resolved, 'top_level' => Woods::FlowAssembler.top_level_constants(names))
    RUBY
    lib = File.expand_path('../lib', __dir__)
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, '-I', lib, '-e', program, JSON.generate(graph.suffix_names))
    raise "ruby probe failed: #{stderr}" unless status.success?

    JSON.parse(stdout)
  end

  def index(units)
    units.each do |unit|
      write_unit(unit[:id], unit[:type] || 'service', unit[:source])
      next if unit[:in_graph] == false

      graph.register(Woods::ExtractedUnit.new(type: (unit[:type] || 'service').to_sym, identifier: unit[:id],
                                              file_path: "app/services/#{unit[:id].downcase}.rb"))
    end
  end

  def write_unit(identifier, type, source)
    directory = File.join(extracted_dir, "#{type}s")
    FileUtils.mkdir_p(directory)
    base = identifier.gsub('::', '__').gsub(/[^a-zA-Z0-9_-]/, '_')
    filename = "#{base}_#{Digest::SHA256.hexdigest(identifier)[0, 8]}.json"
    File.write(File.join(directory, filename),
               JSON.generate('type' => type, 'identifier' => identifier, 'source_code' => source,
                             'file_path' => "app/#{type}s/#{base.downcase}.rb", 'metadata' => {}))
  end

  # @return [Hash] the caller's call operation and the unit the flow expanded
  #   into (nil when it expanded none)
  def woods_answer(caller_id, top_level_constants:)
    assembler = described_class.new(graph: graph, extracted_dir: extracted_dir,
                                    top_level_constants: top_level_constants)
    flow = assembler.assemble("#{caller_id}#call")
    operation = flow.steps.first[:operations].find { |op| op[:type] == :call }
    { operation: operation, expanded: flow.steps[1]&.dig(:unit) }
  end

  def class_with_finder(name)
    "class #{name}\n  def self.create!\n    self\n  end\nend\n"
  end

  describe 'nesting' do
    let(:widget) do
      { id: 'Acme::Widget', source: "module Acme\n  class Widget\n    def self.build\n      self\n    end\n  end\nend\n" }
    end

    it 'agrees with Ruby for a nested module A; module B caller' do
      caller_unit = { id: 'Acme::Reports', source: <<~RUBY }
        module Acme
          class Reports
            def call
              Widget.build
            end
          end
        end
      RUBY
      index([widget, caller_unit])

      ruby = ruby_answer(units: [widget, caller_unit], caller_id: 'Acme::Reports')
      woods = woods_answer('Acme::Reports', top_level_constants: ruby['top_level'])

      expect(ruby['resolved']).to eq('Acme::Widget')
      expect(woods[:expanded]).to eq('Acme::Widget')
    end

    it 'reports ambiguity for a compact module A::B caller when a top-level constant shares the name' do
      caller_unit = { id: 'Acme::Exports', source: <<~RUBY }
        class Acme::Exports
          def call
            Widget.build
          end
        end
      RUBY
      index([widget, caller_unit])

      ruby = ruby_answer(units: [widget, caller_unit], caller_id: 'Acme::Exports',
                         external: "class Widget\n  def self.build\n    self\n  end\nend\n")
      woods = woods_answer('Acme::Exports', top_level_constants: ruby['top_level'])

      # Compact nesting skips Acme, so Ruby reaches the top-level Widget.
      expect(ruby['resolved']).to eq('Widget')
      expect(woods[:expanded]).to be_nil
      expect(woods[:operation][:ambiguous_candidates]).to eq(['::Widget', 'Acme::Widget'])
    end

    it 'names the unique suffix match for a compact caller Ruby would fail (stated limit: not lexical)' do
      caller_unit = { id: 'Acme::Exports', source: <<~RUBY }
        class Acme::Exports
          def call
            Widget.build
          end
        end
      RUBY
      index([widget, caller_unit])

      ruby = ruby_answer(units: [widget, caller_unit], caller_id: 'Acme::Exports')
      woods = woods_answer('Acme::Exports', top_level_constants: ruby['top_level'])

      # Ruby raises NameError; the assembler still follows the one app unit
      # the short name can mean. This is the documented approximation.
      expect(ruby['resolved']).to be_nil
      expect(woods[:expanded]).to eq('Acme::Widget')
    end
  end

  describe 'a top-level constant beside an app unit of the same short name (#967)' do
    let(:external) { "module Translator\n  def self.t(*)\n    self\n  end\nend\n" }
    let(:app_unit) do
      { id: 'Lint::Translator', source: "module Lint\n  class Translator\n    def self.t(*)\n      self\n    end\n  end\nend\n" }
    end

    it 'reports ambiguity, naming the top-level candidate, for a call Ruby sends to the top-level constant' do
      caller_unit = { id: 'GreetingsService',
                      source: "class GreetingsService\n  def call\n    Translator.t(:hi)\n  end\nend\n" }
      index([app_unit, caller_unit])

      ruby = ruby_answer(units: [app_unit, caller_unit], caller_id: 'GreetingsService', external: external)
      woods = woods_answer('GreetingsService', top_level_constants: ruby['top_level'])

      expect(ruby['resolved']).to eq('Translator')
      expect(ruby['top_level']).to include('Translator')
      expect(woods[:expanded]).to be_nil
      expect(woods[:operation][:ambiguous_candidates]).to eq(['::Translator', 'Lint::Translator'])
    end

    it 'reports ambiguity where the app unit shadows the top-level constant inside its namespace' do
      caller_unit = { id: 'Lint::Runner', source: <<~RUBY }
        module Lint
          class Runner
            def call
              Translator.t(:x)
            end
          end
        end
      RUBY
      index([app_unit, caller_unit])

      ruby = ruby_answer(units: [app_unit, caller_unit], caller_id: 'Lint::Runner', external: external)
      woods = woods_answer('Lint::Runner', top_level_constants: ruby['top_level'])

      expect(ruby['resolved']).to eq('Lint::Translator')
      expect(woods[:operation][:ambiguous_candidates]).to eq(['::Translator', 'Lint::Translator'])
    end

    it 'near miss: resolves the app unit as before when no top-level constant has the name' do
      caller_unit = { id: 'Lint::Runner', source: <<~RUBY }
        module Lint
          class Runner
            def call
              Translator.t(:x)
            end
          end
        end
      RUBY
      index([app_unit, caller_unit])

      ruby = ruby_answer(units: [app_unit, caller_unit], caller_id: 'Lint::Runner')
      woods = woods_answer('Lint::Runner', top_level_constants: ruby['top_level'])

      expect(ruby['top_level']).not_to include('Translator')
      expect(ruby['resolved']).to eq('Lint::Translator')
      expect(woods[:expanded]).to eq('Lint::Translator')
      expect(woods[:operation]).not_to have_key(:ambiguous_candidates)
    end
  end

  describe 'inheritance' do
    let(:base) do
      { id: 'BaseService', source: "class BaseService\n  def call\n    nil\n  end\nend\n" }
    end
    let(:result) do
      { id: 'BaseService::Result',
        source: "class BaseService\n  class Result\n    def self.wrap\n      self\n    end\n  end\nend\n" }
    end
    let(:caller_unit) do
      { id: 'ChargeService', source: "class ChargeService < BaseService\n  def call\n    Result.wrap\n  end\nend\n" }
    end

    it 'agrees with Ruby for a constant reached through the superclass' do
      index([base, result, caller_unit])

      ruby = ruby_answer(units: [base, result, caller_unit], caller_id: 'ChargeService')
      woods = woods_answer('ChargeService', top_level_constants: ruby['top_level'])

      expect(ruby['resolved']).to eq('BaseService::Result')
      expect(woods[:expanded]).to eq('BaseService::Result')
    end

    it 'reports ambiguity when a top-level constant shares the name, though Ruby finds the ancestor first' do
      index([base, result, caller_unit])

      ruby = ruby_answer(units: [base, result, caller_unit], caller_id: 'ChargeService',
                         external: "class Result\n  def self.wrap\n    self\n  end\nend\n")
      woods = woods_answer('ChargeService', top_level_constants: ruby['top_level'])

      expect(ruby['resolved']).to eq('BaseService::Result')
      expect(woods[:operation][:ambiguous_candidates]).to eq(['::Result', 'BaseService::Result'])
    end
  end

  describe 'rooted names' do
    let(:billing_invoice) { { id: 'Billing::Invoice', source: "module Billing\n#{class_with_finder('Invoice')}end\n" } }
    let(:top_invoice) { { id: 'Invoice', source: class_with_finder('Invoice'), in_graph: false } }

    it 'resolves a rooted name to its exact unit on disk while a wrong-namespace match sits in the graph' do
      caller_unit = { id: 'Billing::Charge', source: <<~RUBY }
        module Billing
          class Charge
            def call
              ::Invoice.create!
            end
          end
        end
      RUBY
      index([top_invoice, billing_invoice, caller_unit])

      ruby = ruby_answer(units: [top_invoice, billing_invoice, caller_unit], caller_id: 'Billing::Charge')
      woods = woods_answer('Billing::Charge', top_level_constants: ruby['top_level'])

      expect(graph.find_all_by_suffix('Invoice')).to eq(['Billing::Invoice'])
      expect(ruby['resolved']).to eq('Invoice')
      expect(woods[:expanded]).to eq('Invoice')
    end

    it 'leaves a rooted miss unresolved instead of falling back to a suffix match' do
      refund = { id: 'Billing::Refund', source: "module Billing\n#{class_with_finder('Refund')}end\n" }
      caller_unit = { id: 'Billing::Charge', source: <<~RUBY }
        module Billing
          class Charge
            def call
              ::Refund.create!
            end
          end
        end
      RUBY
      index([refund, caller_unit])

      ruby = ruby_answer(units: [refund, caller_unit], caller_id: 'Billing::Charge')
      woods = woods_answer('Billing::Charge', top_level_constants: ruby['top_level'])

      expect(ruby['resolved']).to be_nil
      expect(woods[:expanded]).to be_nil
      expect(woods[:operation]).not_to have_key(:ambiguous_candidates)
    end
  end

  describe 'from extraction to flow' do
    let(:billing_invoice) { { id: 'Billing::Invoice', source: "module Billing\n#{class_with_finder('Invoice')}end\n" } }

    { 'rooted' => '::Billing::Invoice', 'unrooted' => 'Billing::Invoice' }.each do |form, spelling|
      it "expands a #{form} qualified call into the unit Ruby reaches" do
        caller_unit = { id: 'CheckoutService',
                        source: "class CheckoutService\n  def call\n    #{spelling}.create!\n  end\nend\n" }
        index([billing_invoice, caller_unit])

        ruby = ruby_answer(units: [billing_invoice, caller_unit], caller_id: 'CheckoutService')
        woods = woods_answer('CheckoutService', top_level_constants: ruby['top_level'])

        expect(ruby['resolved']).to eq('Billing::Invoice')
        expect(woods[:operation]).to include(target: spelling, method: 'create!')
        expect(woods[:expanded]).to eq('Billing::Invoice')
      end
    end
  end
end
