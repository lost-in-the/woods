# frozen_string_literal: true

require 'spec_helper'
require 'codebase_index/ast/method_extractor'

RSpec.describe CodebaseIndex::Ast::MethodExtractor do
  subject(:extractor) { described_class.new }

  describe '#extract_method' do
    it 'finds a named instance method' do
      source = <<~RUBY
        class Foo
          def bar
            42
          end
        end
      RUBY

      node = extractor.extract_method(source, 'bar')

      expect(node).not_to be_nil
      expect(node.type).to eq(:def)
      expect(node.method_name).to eq('bar')
    end

    it 'returns nil for a missing method' do
      source = <<~RUBY
        class Foo
          def bar; end
        end
      RUBY

      expect(extractor.extract_method(source, 'nonexistent')).to be_nil
    end

    it 'finds a class method when class_method: true' do
      source = <<~RUBY
        class Foo
          def self.build
            new
          end
        end
      RUBY

      node = extractor.extract_method(source, 'build', class_method: true)

      expect(node).not_to be_nil
      expect(node.type).to eq(:defs)
      expect(node.method_name).to eq('build')
    end

    it 'does not match class method when class_method: false' do
      source = <<~RUBY
        class Foo
          def self.build; end
        end
      RUBY

      expect(extractor.extract_method(source, 'build', class_method: false)).to be_nil
    end
  end

  describe '#extract_all_methods' do
    it 'returns all def and defs nodes' do
      source = <<~RUBY
        class Foo
          def bar; end
          def baz; end
          def self.build; end
        end
      RUBY

      methods = extractor.extract_all_methods(source)

      expect(methods.size).to eq(3)
      expect(methods.map(&:method_name)).to contain_exactly('bar', 'baz', 'build')
    end

    it 'returns empty array for source with no methods' do
      source = 'class Foo; end'

      expect(extractor.extract_all_methods(source)).to eq([])
    end
  end

  describe '#extract_method_source' do
    it 'returns exact text of a method' do
      source = <<~RUBY
        class Foo
          def create
            @user = User.find(params[:id])
          end
        end
      RUBY

      result = extractor.extract_method_source(source, 'create')

      expect(result).to include('def create')
      expect(result).to include('User.find')
      expect(result).to include('end')
    end

    it 'returns nil for a missing method' do
      source = 'class Foo; end'

      expect(extractor.extract_method_source(source, 'missing')).to be_nil
    end

    # ── Edge cases that break current heuristics ──────────────────────────

    it 'handles multi-line method signatures' do
      source = <<~RUBY
        class Foo
          def create(
            name:,
            email:,
            role: :user
          )
            User.create!(name: name, email: email, role: role)
          end
        end
      RUBY

      result = extractor.extract_method_source(source, 'create')

      expect(result).to include('def create(')
      expect(result).to include('role: :user')
      expect(result).to include('User.create!')
      expect(result).to include('end')
    end

    it 'handles rescue/ensure inside def' do
      source = <<~RUBY
        class Foo
          def create
            User.create!(params)
          rescue ActiveRecord::RecordInvalid => e
            handle_error(e)
          ensure
            cleanup
          end
        end
      RUBY

      result = extractor.extract_method_source(source, 'create')

      expect(result).to include('def create')
      expect(result).to include('rescue')
      expect(result).to include('ensure')
      expect(result).to include('end')
    end

    it 'handles heredocs in method body' do
      source = <<~'RUBY'
        class Foo
          def generate_sql
            <<~SQL
              SELECT *
              FROM users
              WHERE active = true
            SQL
          end
        end
      RUBY

      result = extractor.extract_method_source(source, 'generate_sql')

      expect(result).to include('def generate_sql')
      expect(result).to include('SQL')
      expect(result).to include('end')
    end

    it 'handles nested def blocks' do
      source = <<~RUBY
        class Foo
          def setup
            define_method(:inner) do
              42
            end
          end
        end
      RUBY

      result = extractor.extract_method_source(source, 'setup')

      expect(result).to include('def setup')
      expect(result).to include('define_method')
    end

    it 'handles method with end in a string literal' do
      source = <<~RUBY
        class Foo
          def message
            "This is the end of the line"
          end
        end
      RUBY

      result = extractor.extract_method_source(source, 'message')

      expect(result).to include('def message')
      expect(result).to include('"This is the end of the line"')
    end

    it 'handles class methods' do
      source = <<~RUBY
        class Foo
          def self.build(attrs)
            new(attrs)
          end
        end
      RUBY

      result = extractor.extract_method_source(source, 'build', class_method: true)

      expect(result).to include('def self.build')
      expect(result).to include('new(attrs)')
    end
  end
end
