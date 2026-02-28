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

  # ── #app_source? ──────────────────────────────────────────────

  describe '#app_source?' do
    let(:app_root) { '/app' }

    it 'returns true for a path inside app_root' do
      expect(utility.app_source?('/app/app/models/user.rb', app_root)).to be true
    end

    it 'returns false for nil path' do
      expect(utility.app_source?(nil, app_root)).to be false
    end

    it 'returns false for a path outside app_root' do
      expect(utility.app_source?('/gems/activerecord/base.rb', app_root)).to be false
    end

    it 'returns false for a vendor bundle path' do
      expect(utility.app_source?('/app/vendor/bundle/ruby/3.3.0/gems/activerecord-7.0.8.7/lib/active_record/base.rb',
                                 app_root)).to be false
    end

    it 'returns false for a node_modules path' do
      expect(utility.app_source?('/app/node_modules/some-package/index.rb', app_root)).to be false
    end
  end

  # ── #resolve_source_location ────────────────────────────────────

  describe '#resolve_source_location' do
    let(:app_root) { '/app' }
    let(:fallback) { '/app/app/models/thing.rb' }

    it 'returns const_source_location when it points to app source' do
      klass = double('Klass', name: 'Thing', instance_methods: [], methods: [])
      allow(Object).to receive(:respond_to?).and_call_original
      allow(Object).to receive(:respond_to?).with(:const_source_location).and_return(true)
      allow(Object).to receive(:const_source_location).with('Thing').and_return(['/app/app/models/thing.rb', 1])

      result = utility.resolve_source_location(klass, app_root: app_root, fallback: fallback)
      expect(result).to eq('/app/app/models/thing.rb')
    end

    it 'skips vendor const_source_location and falls through to instance methods' do
      method_double = double('Method', source_location: ['/app/app/models/thing.rb', 10])
      klass = double('Klass', name: 'Thing', instance_methods: [:foo], methods: [])
      allow(klass).to receive(:instance_method).with(:foo).and_return(method_double)
      allow(Object).to receive(:respond_to?).and_call_original
      allow(Object).to receive(:respond_to?).with(:const_source_location).and_return(true)
      vendor_path = '/app/vendor/bundle/ruby/3.3.0/gems/ar-7.0/lib/ar/base.rb'
      allow(Object).to receive(:const_source_location)
        .with('Thing').and_return([vendor_path, 1])

      result = utility.resolve_source_location(klass, app_root: app_root, fallback: fallback)
      expect(result).to eq('/app/app/models/thing.rb')
    end

    it 'returns instance method location when const_source_location is unavailable' do
      method_double = double('Method', source_location: ['/app/app/models/widget.rb', 5])
      klass = double('Klass', name: 'Widget', instance_methods: [:bar], methods: [])
      allow(klass).to receive(:instance_method).with(:bar).and_return(method_double)
      allow(Object).to receive(:respond_to?).and_call_original
      allow(Object).to receive(:respond_to?).with(:const_source_location).and_return(false)

      result = utility.resolve_source_location(klass, app_root: app_root, fallback: '/app/app/models/widget.rb')
      expect(result).to eq('/app/app/models/widget.rb')
    end

    it 'skips vendor instance method and uses class method' do
      vendor_method = double('Method', source_location: ['/app/vendor/bundle/ruby/3.3.0/gems/foo/lib/foo.rb', 1])
      app_method = double('Method', source_location: ['/app/app/models/thing.rb', 3])
      klass = double('Klass', name: 'Thing', instance_methods: [:vendor_m], methods: [:app_m])
      allow(klass).to receive(:instance_method).with(:vendor_m).and_return(vendor_method)
      allow(klass).to receive(:method).with(:app_m).and_return(app_method)
      allow(Object).to receive(:respond_to?).and_call_original
      allow(Object).to receive(:respond_to?).with(:const_source_location).and_return(false)

      result = utility.resolve_source_location(klass, app_root: app_root, fallback: fallback)
      expect(result).to eq('/app/app/models/thing.rb')
    end

    it 'returns fallback when no methods resolve to app source' do
      klass = double('Klass', name: 'Ghost', instance_methods: [], methods: [])
      allow(Object).to receive(:respond_to?).and_call_original
      allow(Object).to receive(:respond_to?).with(:const_source_location).and_return(false)

      result = utility.resolve_source_location(klass, app_root: app_root, fallback: fallback)
      expect(result).to eq(fallback)
    end

    it 'returns fallback on StandardError' do
      klass = double('Klass', name: 'Broken')
      allow(Object).to receive(:respond_to?).and_call_original
      allow(Object).to receive(:respond_to?).with(:const_source_location).and_return(true)
      allow(Object).to receive(:const_source_location).and_raise(StandardError, 'boom')

      result = utility.resolve_source_location(klass, app_root: app_root, fallback: fallback)
      expect(result).to eq(fallback)
    end
  end

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
