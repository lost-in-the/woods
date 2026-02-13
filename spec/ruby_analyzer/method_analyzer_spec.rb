# frozen_string_literal: true

require 'spec_helper'
require 'codebase_index/ast'
require 'codebase_index/ruby_analyzer/method_analyzer'

RSpec.describe CodebaseIndex::RubyAnalyzer::MethodAnalyzer do
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
      expect(unit.metadata[:parameters]).to be_an(Array)
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
        module CodebaseIndex
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
      expect(unit.identifier).to eq('CodebaseIndex::Extractor#extract_all')
      expect(unit.namespace).to eq('CodebaseIndex::Extractor')
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
end
