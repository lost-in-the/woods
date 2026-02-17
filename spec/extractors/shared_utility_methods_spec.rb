# frozen_string_literal: true

require 'spec_helper'
require 'codebase_index/extractors/shared_utility_methods'

RSpec.describe CodebaseIndex::Extractors::SharedUtilityMethods do
  # Create a test class that includes the module so we can call its methods.
  let(:test_class) do
    Class.new do
      include CodebaseIndex::Extractors::SharedUtilityMethods
    end
  end

  subject(:utility) { test_class.new }

  # ── #extract_namespace ──────────────────────────────────────────

  describe '#extract_namespace' do
    it 'extracts namespace from a namespaced string' do
      expect(utility.extract_namespace('Payments::StripeService')).to eq('Payments')
    end

    it 'extracts multi-level namespace from a deeply nested string' do
      expect(utility.extract_namespace('Admin::Billing::InvoiceService')).to eq('Admin::Billing')
    end

    it 'returns nil for a top-level class name string' do
      expect(utility.extract_namespace('User')).to be_nil
    end

    it 'extracts namespace from a class object with a namespaced name' do
      klass = double('NamespacedClass', name: 'Payments::StripeService')
      expect(utility.extract_namespace(klass)).to eq('Payments')
    end

    it 'returns nil for a top-level class object' do
      klass = double('TopLevelClass', name: 'User')
      expect(utility.extract_namespace(klass)).to be_nil
    end

    it 'handles three-level nesting' do
      expect(utility.extract_namespace('A::B::C::D')).to eq('A::B::C')
    end
  end

  # ── #extract_public_methods ────────────────────────────────────

  describe '#extract_public_methods' do
    it 'extracts public instance methods' do
      source = <<~RUBY
        class Foo
          def greet
          end

          def farewell
          end
        end
      RUBY
      expect(utility.extract_public_methods(source)).to include('greet', 'farewell')
    end

    it 'skips private methods' do
      source = <<~RUBY
        class Foo
          def public_method
          end

          private

          def secret
          end
        end
      RUBY
      result = utility.extract_public_methods(source)
      expect(result).to include('public_method')
      expect(result).not_to include('secret')
    end

    it 'skips protected methods' do
      source = <<~RUBY
        class Foo
          def open_method
          end

          protected

          def guarded
          end
        end
      RUBY
      result = utility.extract_public_methods(source)
      expect(result).to include('open_method')
      expect(result).not_to include('guarded')
    end

    it 'handles public keyword resetting visibility' do
      source = <<~RUBY
        class Foo
          private

          def hidden
          end

          public

          def visible
          end
        end
      RUBY
      result = utility.extract_public_methods(source)
      expect(result).to include('visible')
      expect(result).not_to include('hidden')
    end

    it 'skips underscore-prefixed methods' do
      source = <<~RUBY
        class Foo
          def _internal
          end

          def normal
          end
        end
      RUBY
      result = utility.extract_public_methods(source)
      expect(result).to include('normal')
      expect(result).not_to include('_internal')
    end

    it 'includes self. methods when in public scope' do
      source = <<~RUBY
        class Foo
          def self.class_method
          end
        end
      RUBY
      result = utility.extract_public_methods(source)
      expect(result).to include('self.class_method')
    end

    it 'handles predicate methods with ?' do
      source = <<~RUBY
        class Foo
          def valid?
          end
        end
      RUBY
      expect(utility.extract_public_methods(source)).to include('valid?')
    end

    it 'handles bang methods with !' do
      source = <<~RUBY
        class Foo
          def save!
          end
        end
      RUBY
      expect(utility.extract_public_methods(source)).to include('save!')
    end
  end

  # ── #extract_class_methods ────────────────────────────────────

  describe '#extract_class_methods' do
    it 'extracts self. methods from source' do
      source = <<~RUBY
        class Foo
          def self.create
          end

          def self.find
          end
        end
      RUBY
      result = utility.extract_class_methods(source)
      expect(result).to include('create', 'find')
    end

    it 'handles predicate class methods' do
      source = <<~RUBY
        class Foo
          def self.available?
          end
        end
      RUBY
      expect(utility.extract_class_methods(source)).to include('available?')
    end

    it 'handles bang class methods' do
      source = <<~RUBY
        class Foo
          def self.reset!
          end
        end
      RUBY
      expect(utility.extract_class_methods(source)).to include('reset!')
    end

    it 'handles writer class methods with =' do
      source = <<~RUBY
        class Foo
          def self.config=(val)
          end
        end
      RUBY
      expect(utility.extract_class_methods(source)).to include('config=')
    end

    it 'does not include instance methods' do
      source = <<~RUBY
        class Foo
          def self.class_only
          end

          def instance_only
          end
        end
      RUBY
      result = utility.extract_class_methods(source)
      expect(result).to include('class_only')
      expect(result).not_to include('instance_only')
    end

    it 'returns empty array when no class methods exist' do
      source = 'class Foo; def bar; end; end'
      expect(utility.extract_class_methods(source)).to eq([])
    end
  end

  # ── #extract_initialize_params ────────────────────────────────

  describe '#extract_initialize_params' do
    it 'returns empty array when no initialize method exists' do
      source = 'class Foo; end'
      expect(utility.extract_initialize_params(source)).to eq([])
    end

    it 'extracts positional parameters' do
      source = <<~RUBY
        class Foo
          def initialize(name, age)
          end
        end
      RUBY
      params = utility.extract_initialize_params(source)
      names = params.map { |p| p[:name] }
      expect(names).to include('name', 'age')
    end

    it 'marks keyword arguments' do
      source = <<~RUBY
        class Foo
          def initialize(name:, age:)
          end
        end
      RUBY
      params = utility.extract_initialize_params(source)
      keyword_params = params.select { |p| p[:keyword] }
      expect(keyword_params.map { |p| p[:name] }).to include('name', 'age')
    end

    it 'marks parameters with defaults' do
      source = <<~RUBY
        class Foo
          def initialize(name: 'default', active: true)
          end
        end
      RUBY
      params = utility.extract_initialize_params(source)
      name_param = params.find { |p| p[:name] == 'name' }
      expect(name_param[:has_default]).to be true
    end

    it 'marks required parameters without defaults' do
      source = <<~RUBY
        class Foo
          def initialize(name:)
          end
        end
      RUBY
      params = utility.extract_initialize_params(source)
      name_param = params.find { |p| p[:name] == 'name' }
      expect(name_param[:has_default]).to be false
    end
  end
end
