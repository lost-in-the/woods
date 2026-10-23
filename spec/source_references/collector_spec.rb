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

      it 'records only the immediate constant receiver selector, not arguments or later dispatch' do
        records = references(<<~SOURCE)
          class Caller
            Target.call(Argument)
            Target.new.execute
            Target.call.deliver
            Target.send(:execute)
            Target.public_send(MethodName)
            consume(Target)
            Target
          end
        SOURCE
        expected = [
          { 'name' => 'Target', 'method' => 'call' }, { 'name' => 'Argument' },
          { 'name' => 'Target', 'method' => 'new' }, { 'name' => 'Target', 'method' => 'call' },
          { 'name' => 'Target', 'method' => 'send' }, { 'name' => 'Target', 'method' => 'public_send' },
          { 'name' => 'MethodName' }, { 'name' => 'Target' }, { 'name' => 'Target' }
        ]
        expect(records.map { |record| record.slice('name', 'method') }).to eq(expected)
      end

      it 'retains syntactic safe, operator, index, setter and shorthand selectors' do
        expressions = {
          'Target&.ready?' => 'ready?', 'Target.save!' => 'save!', 'Target + Argument' => '+',
          '-Target' => '-@', 'Target[Argument]' => '[]', 'Target[Argument] = Value' => '[]=',
          'Target.value = Argument' => 'value=', 'Target.()' => 'call', 'Target::call' => 'call',
          '(Target).call' => 'call', '((Target)).call' => 'call',
          'Target.écrire' => 'écrire'
        }
        expressions.each do |expression, selector|
          records = references("class Caller; #{expression}; end")
          expect(records.first).to include('name' => 'Target', 'method' => selector)
          expect(records.drop(1)).to all(satisfy { |record| !record.key?('method') })
        end
      end

      it 'does not infer a constant receiver from a group with preceding expressions' do
        records = references('class Caller; (Other.call; Target).work; end')
        expected = [{ 'name' => 'Other', 'method' => 'call' }, { 'name' => 'Target' }]
        expect(records.map { |record| record.slice('name', 'method') }).to eq(expected)
      end

      it 'omits selectors exceeding the shared 4096-byte evidence bound without losing constant spans' do
        records = references("class Caller; Target.#{'é' * 2048}; Target.#{'é' * 2049}; end")
        expect(records.first.fetch('method')).to eq('é' * 2048)
        expect(records.last).to include('name' => 'Target', 'length' => 6)
        expect(records.last).not_to have_key('method')
      end

      it 'normalizes a selector from the declared source encoding to UTF-8' do
        source = "# encoding: ISO-8859-1\nclass Caller; Target.écrire; end\n".encode(Encoding::ISO_8859_1)
        record = references(source).first
        expect(record).to include('name' => 'Target', 'method' => 'écrire')
        expect(record.fetch('method').encoding).to eq(Encoding::UTF_8)
      end

      it 'omits a selector for compound writes while retaining their receiver, arguments and nested calls' do
        records = references(<<~SOURCE)
          class Caller
            Target.value += Other.call
            Target.value ||= Other
            Target.value &&= Other
            Target[Index.call] += Value.call
            Target[Index] ||= Value
            Target[Index] &&= Value
            Target.build.value += Other.call
          end
        SOURCE
        expected = [
          { 'name' => 'Target' }, { 'name' => 'Other', 'method' => 'call' },
          { 'name' => 'Target' }, { 'name' => 'Other' }, { 'name' => 'Target' }, { 'name' => 'Other' },
          { 'name' => 'Target' }, { 'name' => 'Index', 'method' => 'call' }, { 'name' => 'Value', 'method' => 'call' },
          { 'name' => 'Target' }, { 'name' => 'Index' }, { 'name' => 'Value' },
          { 'name' => 'Target' }, { 'name' => 'Index' }, { 'name' => 'Value' },
          { 'name' => 'Target', 'method' => 'build' }, { 'name' => 'Other', 'method' => 'call' }
        ]
        expect(records.map { |record| record.slice('name', 'method') }).to eq(expected)
      end

      it 'keeps dynamic-scope exclusions ahead of receiver selector collection' do
        result = collector.call(<<~SOURCE)
          class Caller
            Target.class_eval { Hidden.call }
            Target.module_eval { Hidden.call }
            Target.define_method(:read) { Hidden.call }
            Target.define_singleton_method(:read) { Hidden.call }
            define_method(:read) { Local.call }
            Target.call(Other.work, Bare) { Argument.call }
          end
        SOURCE
        expected = [
          { 'name' => 'Local', 'method' => 'call' }, { 'name' => 'Target', 'method' => 'call' },
          { 'name' => 'Other', 'method' => 'work' }, { 'name' => 'Bare' }, { 'name' => 'Argument', 'method' => 'call' }
        ]
        expect(result.fetch('references').map { |record| record.slice('name', 'method') }).to eq(expected)
        expect(result.fetch('skipped').map { |record| record.fetch('reason') }).to eq(['dynamic_declaration'] * 4)
      end

      it 'retains a bare receiver span for a rescue attribute assignment target' do
        source = 'class Caller; begin; work; rescue => Target.error; end; end'
        records = references(source)
        expected = [{ 'owner' => 'Caller', 'nesting' => ['Caller'], 'name' => 'Target',
                      'line' => 1, 'column' => 37, 'length' => 6 }]
        expect(records).to eq(expected)
      end

      it 'retains rescue index targets without losing their argument calls' do
        records = references('class Caller; begin; work; rescue => Target[Index.call]; end; end')
        expected = [{ 'name' => 'Target' }, { 'name' => 'Index', 'method' => 'call' }]
        expect(records.map { |record| record.slice('name', 'method') }).to eq(expected)
        expect(records.first).to include('line' => 1, 'column' => 37, 'length' => 6)
      end

      it 'omits selectors on nested for assignment targets while retaining collection and body calls' do
        records = references(<<~SOURCE)
          class Caller
            for (Target.value, (Other.value, *Target[Index.call])) in Values.call
              Body.call
            end
          end
        SOURCE
        expected = [
          { 'name' => 'Target' }, { 'name' => 'Other' }, { 'name' => 'Target' },
          { 'name' => 'Index', 'method' => 'call' }, { 'name' => 'Values', 'method' => 'call' },
          { 'name' => 'Body', 'method' => 'call' }
        ]
        expect(records.map { |record| record.slice('name', 'method') }).to eq(expected)
      end

      it 'keeps nested receiver calls and ordinary explicit setters distinct from assignment targets' do
        records = references(<<~SOURCE)
          class Caller
            begin
              work
            rescue => Factory.build.error
            end
            for Factory.build[Index.call] in Values
            end
            for Target.value in Values
            end
            Target.error = Value
            Target[Index.call] = Value
          end
        SOURCE
        expected = [
          { 'name' => 'Factory', 'method' => 'build' }, { 'name' => 'Factory', 'method' => 'build' },
          { 'name' => 'Index', 'method' => 'call' }, { 'name' => 'Values' },
          { 'name' => 'Target' }, { 'name' => 'Values' },
          { 'name' => 'Target', 'method' => 'error=' }, { 'name' => 'Value' },
          { 'name' => 'Target', 'method' => '[]=' }, { 'name' => 'Index', 'method' => 'call' },
          { 'name' => 'Value' }
        ]
        expect(records.map { |record| record.slice('name', 'method') }).to eq(expected)
      end

      it 'keeps whole repeated rooted Unicode receivers in original CRLF byte coordinates' do
        source = "class Caller\r\n  'é'; ::Späce::\r\n    Tárget.call; ::Späce::Tárget.new\r\nend\r\n"
        records = references(source)
        expected = [['::Späce::Tárget', 2, 8, 23, 'call'], ['::Späce::Tárget', 3, 18, 17, 'new']]
        expect(records.map { |record| record.values_at('name', 'line', 'column', 'length', 'method') }).to eq(expected)
      end

      it 'associates a selector on a later line only with its receiver' do
        records = references("class Caller\r\n  Target\r\n    .call(Argument)\r\nend\r\n")
        expect(records.first).to include('name' => 'Target', 'line' => 2, 'column' => 2, 'length' => 6,
                                         'method' => 'call')
        expect(records.last).to include('name' => 'Argument')
        expect(records.last).not_to have_key('method')
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
            'name' => 'TokenGenerator', 'line' => 2, 'method' => 'generate' },
          { 'owner' => 'CheckoutController', 'nesting' => ['CheckoutController'],
            'name' => 'Billing::Parser', 'line' => 3, 'method' => 'default' },
          { 'owner' => 'CheckoutController', 'nesting' => ['CheckoutController'],
            'name' => 'Domain::Vendor::PlanChange', 'line' => 4, 'method' => 'new' },
          { 'owner' => 'CheckoutController', 'nesting' => ['CheckoutController'],
            'name' => '::TokenCodec', 'line' => 6 },
          { 'owner' => 'CheckoutController', 'nesting' => ['CheckoutController'],
            'name' => 'CodecRegistry', 'line' => 7, 'method' => 'fetch' }
        ]
        expect(result['references'].map { |record| record.except('column', 'length') }).to eq(expected)
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
        expected = [{ 'owner' => 'Caller', 'nesting' => ['Caller'], 'name' => 'TokenGenerator', 'line' => 5,
                      'method' => 'generate' }]
        expect(result['references'].map { |record| record.except('column', 'length') }).to eq(expected)
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
        expected = [{ 'owner' => 'Caller', 'nesting' => %w[Caller Domain], 'name' => 'Target', 'line' => 1,
                      'method' => 'call' }]
        expect(references(source).map { |record| record.except('column', 'length') }).to eq(expected)
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

      it 'retains whole repeated spans in UTF-8 bytes across CRLF and nested owners' do
        source = "class Caller\r\n  'é'; ::Space::Target.call; ::Space::Target.call\r\n  " \
                 "class Inner; Target.call; end\r\nend\r\n"
        actual = references(source).map { |record| record.values_at('owner', 'name', 'line', 'column', 'length') }
        expect(actual).to eq([
                               ['Caller', '::Space::Target', 2, 8, 15],
                               ['Caller', '::Space::Target', 2, 30, 15],
                               ['Caller::Inner', 'Target', 3, 15, 6]
                             ])
      end

      it 'honors a magic encoding when converting parser character offsets back to captured bytes' do
        source = "# encoding: ISO-8859-1\r\nclass Caller; 'é'; Target.call; end\r\n".b
        expect(references(source).first).to include('line' => 2, 'column' => 20, 'length' => 6)
      end

      it 'measures multiline qualified constants against original bytes' do
        source = "class Caller\r\n  Space::\r\n    Target.call\r\nend\r\n"
        expect(references(source).first).to include('line' => 2, 'column' => 2, 'length' => 19)
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
