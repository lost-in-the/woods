# frozen_string_literal: true

require 'spec_helper'
require 'woods/ast'
require 'woods/ruby_analyzer/method_analyzer'

RSpec.describe Woods::RubyAnalyzer::MethodAnalyzer do
  subject(:analyzer) { described_class.new }

  describe '#analyze' do
    it 'extracts instance methods' do
      source = <<~RUBY
        class Greeter
          def greet(name)
            "Hello, \#{name}"
          end
        end
      RUBY

      units = analyzer.analyze(source: source, file_path: '/app/greeter.rb')

      expect(units.size).to eq(1)
      unit = units.first
      expect(unit.type).to eq(:ruby_method)
      expect(unit.identifier).to eq('Greeter#greet')
      expect(unit.file_path).to eq('/app/greeter.rb')
      expect(unit.metadata[:visibility]).to eq(:public)
    end

    it 'extracts class methods with dot notation' do
      source = <<~RUBY
        class Builder
          def self.build(attrs)
            new(attrs)
          end
        end
      RUBY

      units = analyzer.analyze(source: source, file_path: '/app/builder.rb')

      expect(units.size).to eq(1)
      unit = units.first
      expect(unit.type).to eq(:ruby_method)
      expect(unit.identifier).to eq('Builder.build')
    end

    it 'extracts methods from namespaced classes' do
      source = <<~RUBY
        module Woods
          class Extractor
            def extract_all
              []
            end
          end
        end
      RUBY

      units = analyzer.analyze(source: source, file_path: '/lib/extractor.rb')

      expect(units.size).to eq(1)
      unit = units.first
      expect(unit.identifier).to eq('Woods::Extractor#extract_all')
      expect(unit.namespace).to eq('Woods::Extractor')
    end

    it 'detects private methods' do
      source = <<~RUBY
        class Foo
          def public_method; end

          private

          def secret_method; end
        end
      RUBY

      units = analyzer.analyze(source: source, file_path: '/app/foo.rb')

      public_unit = units.find { |u| u.identifier == 'Foo#public_method' }
      private_unit = units.find { |u| u.identifier == 'Foo#secret_method' }

      expect(public_unit.metadata[:visibility]).to eq(:public)
      expect(private_unit.metadata[:visibility]).to eq(:private)
    end

    it 'detects protected methods' do
      source = <<~RUBY
        class Foo
          protected

          def guarded_method; end
        end
      RUBY

      units = analyzer.analyze(source: source, file_path: '/app/foo.rb')
      unit = units.first

      expect(unit.metadata[:visibility]).to eq(:protected)
    end

    it 'extracts call graph from method bodies' do
      source = <<~RUBY
        class UserService
          def create_user(params)
            user = User.create!(params)
            NotificationService.notify(user)
            user
          end
        end
      RUBY

      units = analyzer.analyze(source: source, file_path: '/app/user_service.rb')
      unit = units.first

      expect(unit.metadata[:call_graph]).to be_an(Array)
      expect(unit.metadata[:call_graph]).to include(
        a_hash_including(target: 'User', method: 'create!')
      )
      expect(unit.metadata[:call_graph]).to include(
        a_hash_including(target: 'NotificationService', method: 'notify')
      )
    end

    it 'keeps calls on absolute constants in the call graph' do
      source = <<~RUBY
        class Loader
          def load
            ::Parser::CurrentRuby.parse('')
          end
        end
      RUBY

      unit = analyzer.analyze(source: source, file_path: '/app/loader.rb').first

      expect(unit.metadata[:call_graph]).to eq([{ target: '::Parser::CurrentRuby', method: 'parse', line: 3 }])
      expect(unit.dependencies).to eq([{ type: :ruby_class, target: '::Parser::CurrentRuby', via: :method_call }])
    end

    it 'generates dependencies from call graph receivers' do
      source = <<~RUBY
        class Processor
          def run
            Parser.parse(input)
          end
        end
      RUBY

      units = analyzer.analyze(source: source, file_path: '/app/processor.rb')
      unit = units.first

      expect(unit.dependencies).to include(
        a_hash_including(type: :ruby_class, target: 'Parser', via: :method_call)
      )
    end

    it 'handles a class with no methods' do
      source = <<~RUBY
        class Empty
        end
      RUBY

      units = analyzer.analyze(source: source, file_path: '/app/empty.rb')
      expect(units).to eq([])
    end

    it 'extracts methods from modules' do
      source = <<~RUBY
        module Helpers
          def help
            "helping"
          end
        end
      RUBY

      units = analyzer.analyze(source: source, file_path: '/lib/helpers.rb')

      expect(units.size).to eq(1)
      expect(units.first.identifier).to eq('Helpers#help')
    end

    it 'includes source code of each method' do
      source = <<~RUBY
        class Foo
          def bar
            42
          end
        end
      RUBY

      units = analyzer.analyze(source: source, file_path: '/app/foo.rb')

      expect(units.first.source_code).to include('def bar')
      expect(units.first.source_code).to include('42')
    end

    it 'handles multiple classes in one file' do
      source = <<~RUBY
        class Foo
          def foo_method; end
        end

        class Bar
          def bar_method; end
        end
      RUBY

      units = analyzer.analyze(source: source, file_path: '/app/multi.rb')

      expect(units.size).to eq(2)
      expect(units.map(&:identifier)).to contain_exactly('Foo#foo_method', 'Bar#bar_method')
    end
  end

  describe 'definitions that share one line' do
    [true, false].each do |use_prism|
      context "with Prism=#{use_prism}" do
        before { allow_any_instance_of(Woods::Ast::Parser).to receive(:prism_available?).and_return(use_prism) }

        def bodies(source)
          analyzer.analyze(source: source, file_path: '/app/line.rb').to_h do |unit|
            [unit.identifier, [unit.source_code, unit.metadata[:call_graph].map { |call| call[:target] }]]
          end
        end

        it 'keeps an instance and a singleton method of one name apart' do
          source = "class A; def a; Left.call; end; def self.a; Right.call; end; end\n"

          expect(bodies(source)).to eq('A#a' => ['def a; Left.call; end', ['Left']],
                                       'A.a' => ['def self.a; Right.call; end', ['Right']])
        end

        it 'keeps the methods of two owners on one line apart' do
          source = "class A; def a; Left.call; end; end; class B; def a; Right.call; end; end\n"

          expect(bodies(source)).to eq('A#a' => ['def a; Left.call; end', ['Left']],
                                       'B#a' => ['def a; Right.call; end', ['Right']])
        end

        it 'holds the later of two definitions on one line, the body Ruby calls' do
          source = "class A; def a; Left.call; end; def a; Right.call; end; end\n"
          namespace = Module.new
          { Left: :left, Right: :right }.each do |name, result|
            namespace.const_set(name, Module.new.tap { |target| target.define_singleton_method(:call) { result } })
          end
          namespace.module_eval(source)

          expect(namespace::A.new.a).to eq(:right)
          expect(bodies(source)).to eq('A#a' => ['def a; Right.call; end', ['Right']])
        end
      end
    end

    it 'keeps the whole lines of a definition no other definition shares' do
      source = "class A\n  private def a\n    Left.call\n  end\nend\n"

      expect(analyzer.analyze(source: source, file_path: '/app/line.rb').first.source_code)
        .to eq("  private def a\n    Left.call\n  end\n")
    end

    it 'publishes no join key in the method table' do
      source = "class A; def a; end; def self.a; end; end\n"

      expect(Woods::MethodTable.call(source).flat_map(&:keys).uniq)
        .to match_array(%w[name kind line end_line visibility owner])
    end
  end
end
