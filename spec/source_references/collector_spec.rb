# frozen_string_literal: true

require 'spec_helper'
require 'json'
require 'woods/source_references/collector'

RSpec.describe Woods::SourceReferences::Collector do
  %i[prism parser].each do |backend|
    context "with #{backend}" do
      subject(:collector) { described_class.new(backend: backend) }

      def references(source)
        collector.call(source).fetch('references')
      end

      def names(source)
        references(source).map { |reference| reference.fetch('name') }
      end

      it 'records literal value-class assignments without attributing their dynamic block bodies' do
        result = collector.call(<<~SOURCE)
          module ValueSpace
            Item = Struct.new(:value) do
              def call
                Hidden.call
              end
            end
            ::RootValue = ::Data.define(:value)
            AliasValue = Item
            OtherValue = Class.new
          end
        SOURCE
        assignments = result['declarations'].select { |record| record.key?('constructor') }
        expected = [
          ['ValueSpace::Item', 'Struct', ['ValueSpace']], ['RootValue', '::Data', ['ValueSpace']]
        ]
        actual = assignments.map { |record| record.values_at('owner', 'constructor', 'enclosing_nesting') }
        expect(actual).to eq(expected)
        expect(result['references'].map { |record| record['name'] }).not_to include('Hidden')
        expect(result['skipped']).to include(hash_including('reason' => 'dynamic_declaration'))
      end

      it 'captures qualified constructors, callback calls, arguments and method defaults' do
        source = <<~RUBY_SOURCE
          class CheckoutController < ApplicationController
            before_validation { TokenGenerator.generate }
            def update(plan = Billing::Parser.default)
              redirect_to Domain::Vendor::PlanChange.new(account, new_plan: plan).execute
            end
            def self.decode(codec = ::TokenCodec)
              CodecRegistry.fetch(codec)
            end
          end
        RUBY_SOURCE
        result = collector.call(source)

        expect(result['parse_error']).to be_nil
        expect(result['skipped']).to be_empty
        expected = [
          { 'owner' => 'CheckoutController', 'nesting' => ['CheckoutController'],
            'name' => 'TokenGenerator', 'line' => 2 },
          { 'owner' => 'CheckoutController', 'nesting' => ['CheckoutController'],
            'name' => 'Billing::Parser', 'line' => 3 },
          { 'owner' => 'CheckoutController', 'nesting' => ['CheckoutController'],
            'name' => 'Domain::Vendor::PlanChange', 'line' => 4 },
          { 'owner' => 'CheckoutController', 'nesting' => ['CheckoutController'],
            'name' => '::TokenCodec', 'line' => 6 },
          { 'owner' => 'CheckoutController', 'nesting' => ['CheckoutController'],
            'name' => 'CodecRegistry', 'line' => 7 }
        ]
        expect(result['references']).to eq(expected)
        expect(JSON.parse(JSON.generate(result))).to eq(result)
      end

      it 'preserves nested and compact lexical nesting without crediting nested bodies to their outer owner' do
        source = <<~RUBY_SOURCE
          module Domain
            class Caller
              Parser.call
              class Helper
                TokenCodec.decode
              end
            end
            class Vendor::Caller
              Parser.call
            end
          end
          class Domain::Caller
            Parser.call
          end
          class ::RootCaller
            ::Parser.call
          end
        RUBY_SOURCE
        result = collector.call(source)
        expected = [
          ['Domain::Caller', ['Domain::Caller', 'Domain'], 'Parser'],
          ['Domain::Caller::Helper', ['Domain::Caller::Helper', 'Domain::Caller', 'Domain'], 'TokenCodec'],
          ['Domain::Vendor::Caller', ['Domain::Vendor::Caller', 'Domain'], 'Parser'],
          ['Domain::Caller', ['Domain::Caller'], 'Parser'],
          ['RootCaller', ['RootCaller'], '::Parser']
        ]
        expect(result['references'].map { |ref| ref.values_at('owner', 'nesting', 'name') }).to eq(expected)
        expect(result['declarations'][3]).to eq(
          'owner' => 'Domain::Vendor::Caller', 'name' => 'Vendor::Caller', 'kind' => 'class',
          'nesting' => ['Domain::Vendor::Caller', 'Domain'], 'enclosing_nesting' => ['Domain'],
          'line' => 8, 'end_line' => 10
        )
      end

      it 'ignores declaration names, superclass headers, comments, strings, symbols and assignment targets' do
        source = <<~RUBY_SOURCE
          class Outer < Namespace::Parent
            # Commented::Missing.call
            TEXT = 'String::Missing'
            PATTERN = /Regexp::Missing/
            SYMBOL = :'Symbol::Missing'
            DOC = <<~TEXT
              Heredoc::Missing
            TEXT
            Namespace::Assigned = SourceValue
            Left, Right = FirstValue, SecondValue
            READ = Namespace::Parent
          end
        RUBY_SOURCE
        expect(names(source)).to eq(%w[SourceValue FirstValue SecondValue Namespace::Parent])
      end

      it 'captures executable interpolation and rescue exception references' do
        source = <<~'RUBY_SOURCE'
          class Caller
            def call
              "result #{StringCodec.call}"
              /#{PatternCodec.call}/
              :"#{SymbolCodec.call}"
              <<~TEXT
                #{HeredocCodec.call}
              TEXT
            rescue DecodeError
              ErrorReporter.report
            end
          end
        RUBY_SOURCE
        expect(names(source)).to eq(%w[StringCodec PatternCodec SymbolCodec HeredocCodec DecodeError ErrorReporter])
      end

      it 'keeps self singleton scope and reports uncertain owners without leaking their bodies' do
        source = <<~RUBY_SOURCE
          class Caller
            class << self
              TokenCodec.decode
            end
            class << factory
              NotCaller.decode
            end
            def other.call
              NotCaller.decode
            end
            Generated = Class.new do
              NotCaller.decode
            end
            class factory::Generated
              NotCaller.decode
            end
            factory::Dynamic.decode
          end
        RUBY_SOURCE
        result = collector.call(source)
        expect(result['references'].map { |ref| ref['name'] }).to eq(['TokenCodec'])
        reasons = %w[
          dynamic_singleton_scope dynamic_method_owner dynamic_declaration dynamic_declaration dynamic_constant_path
        ]
        expect(result['skipped'].map { |item| item['reason'] }).to eq(reasons)
      end

      it 'marks singleton-class lookup without leaking its context into later methods' do
        source = <<~RUBY_SOURCE
          class Caller
            class << self
              TokenCodec = OtherCodec
              TokenCodec.decode
              class Helper
                TokenCodec.decode
              end
              class << self
                TokenCodec.decode
              end
            end
            def self.decode
              TokenCodec.decode
            end
            TokenCodec.decode
          end
        RUBY_SOURCE
        result = collector.call(source)
        expect(result['references'].map { |ref| ref['singleton_depth'] }).to eq([1, 1, 1, 2, nil, nil])
        helper = result['declarations'].find { |declaration| declaration['name'] == 'Helper' }
        expect(helper['singleton_depth']).to eq(1)
        expect(result['declarations'].first).not_to have_key('singleton_depth')
      end

      it 'does not borrow owners across eval blocks or anonymous class factories' do
        source = <<~RUBY_SOURCE
          class Caller
            module_eval { NotCaller.call }
            Other.class_exec { NotCaller.call }
            Anonymous = Struct.new(:value) { NotCaller.call }
            Immutable = Data.define(:value) { NotCaller.call }
            Other.define_method(:read) { NotCaller.call }
            define_method(:read) { LocalMethod.call }
          end
        RUBY_SOURCE
        result = collector.call(source)
        expect(result['references'].map { |ref| ref['name'] }).to eq(['LocalMethod'])
        expect(result['skipped'].size).to eq(5)
        expect(result['skipped'].map { |item| item['reason'] }.uniq).to eq(['dynamic_declaration'])
      end

      it 'applies dynamic ownership exclusions to numbered parameter blocks' do
        source = <<~RUBY_SOURCE
          class Caller
            Other.class_eval { _1; NotCaller.call }
            Other.define_method(:read) { _1; NotCaller.call }
            Anonymous = Class.new { _1; NotCaller.call }
            before_validation { TokenGenerator.generate(_1) }
          end
        RUBY_SOURCE
        result = collector.call(source)
        expected = [{ 'owner' => 'Caller', 'nesting' => ['Caller'], 'name' => 'TokenGenerator', 'line' => 5 }]
        expect(result['references']).to eq(expected)
        skipped = [
          { 'owner' => 'Caller', 'reason' => 'dynamic_declaration', 'line' => 2 },
          { 'owner' => 'Caller', 'reason' => 'dynamic_declaration', 'line' => 3 },
          { 'owner' => 'Caller', 'reason' => 'dynamic_declaration', 'line' => 4 }
        ]
        expect(result['skipped']).to eq(skipped)
      end

      it 'reports dynamic inheritance without inventing a superclass reference' do
        source = 'class Caller < build_parent(ParentCandidate); BodyTarget.call; end'
        result = collector.call(source)
        expect(result['references'].map { |ref| ref['name'] }).to eq(['BodyTarget'])
        expect(result['skipped']).to eq([{ 'owner' => 'Caller', 'reason' => 'dynamic_superclass', 'line' => 1 }])
      end

      it 'preserves enclosing lexical nesting when a declaration is rooted' do
        source = 'module Domain; class ::Caller; Target.call; end; end'
        expected = [{ 'owner' => 'Caller', 'nesting' => %w[Caller Domain], 'name' => 'Target', 'line' => 1 }]
        expect(references(source)).to eq(expected)
      end

      it 'collects right-hand sides of constant operator assignments and optional keyword parameters' do
        source = <<~RUBY_SOURCE
          class Caller
            CACHE ||= CacheFactory.build
            Other::CACHE &&= CacheFactory.reset
            VALUE += MoreValue
            def call(required:, option: DefaultValue)
              required
            end
          end
        RUBY_SOURCE
        expect(names(source)).to eq(%w[CacheFactory CacheFactory MoreValue DefaultValue])
      end

      it 'does not attribute top-level code to the next or previous declaration' do
        result = collector.call('Before.call; class First; Inside.call; end; Between.call; class Last; After.call; end')
        expected = [%w[First Inside], %w[Last After]]
        expect(result['references'].map { |ref| ref.values_at('owner', 'name') }).to eq(expected)
        expect(result['skipped'].map { |item| item['reason'] }).to eq(%w[unowned_reference unowned_reference])
      end

      it 'does not emit shortened namespace prefixes or deduplicate source occurrences' do
        expect(names('class Caller; Namespace::Missing.call; Namespace::Missing.call; end'))
          .to eq(['Namespace::Missing', 'Namespace::Missing'])
      end

      it 'returns a parse failure and no partial references on invalid source' do
        result = collector.call('class Caller; TokenCodec.call; def broken(')
        expect(result['parse_error']).to include('message' => a_kind_of(String), 'line' => a_kind_of(Integer))
        expect(result.values_at('declarations', 'references', 'skipped')).to eq([[], [], []])
      end

      it 'returns an empty successful result for empty input and can be reused' do
        collector.call('class Caller; TokenCodec.call; end')
        expect(collector.call('')).to eq('declarations' => [], 'references' => [], 'skipped' => [],
                                         'parse_error' => nil)
      end
    end
  end

  it 'rejects unsupported backends' do
    expect { described_class.new(backend: :other) }.to raise_error(ArgumentError, /backend/)
  end
end
