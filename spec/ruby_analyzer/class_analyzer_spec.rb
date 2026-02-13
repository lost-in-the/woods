# frozen_string_literal: true

require 'spec_helper'
require 'codebase_index/ast'
require 'codebase_index/ruby_analyzer/class_analyzer'

RSpec.describe CodebaseIndex::RubyAnalyzer::ClassAnalyzer do
  subject(:analyzer) { described_class.new }

  describe '#analyze' do
    it 'extracts a simple class' do
      source = <<~RUBY
        class Greeter
          def greet
            "hello"
          end
        end
      RUBY

      units = analyzer.analyze(source: source, file_path: '/app/greeter.rb')

      expect(units.size).to eq(1)
      unit = units.first
      expect(unit.type).to eq(:ruby_class)
      expect(unit.identifier).to eq('Greeter')
      expect(unit.file_path).to eq('/app/greeter.rb')
      expect(unit.source_code).to include('class Greeter')
      expect(unit.metadata[:superclass]).to be_nil
      expect(unit.metadata[:method_count]).to eq(1)
    end

    it 'extracts a class with a superclass' do
      source = <<~RUBY
        class Admin < User
          def admin?
            true
          end
        end
      RUBY

      units = analyzer.analyze(source: source, file_path: '/app/admin.rb')
      unit = units.first

      expect(unit.type).to eq(:ruby_class)
      expect(unit.identifier).to eq('Admin')
      expect(unit.metadata[:superclass]).to eq('User')
      expect(unit.dependencies).to include(
        a_hash_including(type: :ruby_class, target: 'User', via: :inheritance)
      )
    end

    it 'extracts a namespaced class' do
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

      class_unit = units.find { |u| u.type == :ruby_class }
      expect(class_unit.identifier).to eq('CodebaseIndex::Extractor')
      expect(class_unit.namespace).to eq('CodebaseIndex')
    end

    it 'extracts a module' do
      source = <<~RUBY
        module Helpers
          def help
            "helping"
          end
        end
      RUBY

      units = analyzer.analyze(source: source, file_path: '/lib/helpers.rb')

      expect(units.size).to eq(1)
      unit = units.first
      expect(unit.type).to eq(:ruby_module)
      expect(unit.identifier).to eq('Helpers')
      expect(unit.metadata[:method_count]).to eq(1)
    end

    it 'extracts deeply nested classes' do
      source = <<~RUBY
        module A
          module B
            class C
              def foo; end
            end
          end
        end
      RUBY

      units = analyzer.analyze(source: source, file_path: '/lib/abc.rb')

      class_unit = units.find { |u| u.type == :ruby_class }
      expect(class_unit.identifier).to eq('A::B::C')
      expect(class_unit.namespace).to eq('A::B')

      module_a = units.find { |u| u.identifier == 'A' }
      expect(module_a.type).to eq(:ruby_module)

      module_b = units.find { |u| u.identifier == 'A::B' }
      expect(module_b.type).to eq(:ruby_module)
    end

    it 'detects include and extend' do
      source = <<~RUBY
        class User
          include Comparable
          extend ClassMethods

          def name; end
        end
      RUBY

      units = analyzer.analyze(source: source, file_path: '/app/user.rb')
      unit = units.first

      expect(unit.metadata[:includes]).to include('Comparable')
      expect(unit.metadata[:extends]).to include('ClassMethods')
      expect(unit.dependencies).to include(
        a_hash_including(type: :ruby_class, target: 'Comparable', via: :include)
      )
      expect(unit.dependencies).to include(
        a_hash_including(type: :ruby_class, target: 'ClassMethods', via: :extend)
      )
    end

    it 'detects constants defined in a class' do
      source = <<~RUBY
        class Config
          VERSION = "1.0"
          MAX_RETRIES = 3
        end
      RUBY

      units = analyzer.analyze(source: source, file_path: '/lib/config.rb')
      unit = units.first

      expect(unit.metadata[:constants]).to include('VERSION', 'MAX_RETRIES')
    end

    it 'handles an empty class' do
      source = <<~RUBY
        class Empty
        end
      RUBY

      units = analyzer.analyze(source: source, file_path: '/app/empty.rb')

      expect(units.size).to eq(1)
      unit = units.first
      expect(unit.metadata[:method_count]).to eq(0)
      expect(unit.metadata[:includes]).to eq([])
      expect(unit.metadata[:extends]).to eq([])
      expect(unit.metadata[:constants]).to eq([])
    end

    it 'handles a file with no classes or modules' do
      source = <<~RUBY
        puts "hello"
        x = 1 + 2
      RUBY

      units = analyzer.analyze(source: source, file_path: '/script.rb')

      expect(units).to eq([])
    end

    it 'counts both instance and class methods' do
      source = <<~RUBY
        class Foo
          def bar; end
          def baz; end
          def self.build; end
        end
      RUBY

      units = analyzer.analyze(source: source, file_path: '/app/foo.rb')
      unit = units.first

      expect(unit.metadata[:method_count]).to eq(3)
    end

    it 'handles inline constant path class names' do
      source = <<~RUBY
        class Foo::Bar
          def run; end
        end
      RUBY

      units = analyzer.analyze(source: source, file_path: '/lib/foo/bar.rb')
      unit = units.find { |u| u.type == :ruby_class }

      expect(unit.identifier).to eq('Foo::Bar')
      expect(unit.namespace).to eq('Foo')
    end
  end
end
