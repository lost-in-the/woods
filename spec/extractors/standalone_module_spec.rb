# frozen_string_literal: true

require 'spec_helper'
require 'set'
require 'tmpdir'
require 'fileutils'
require 'active_support/core_ext/object/blank'
require 'active_support/core_ext/string/inflections'
require 'woods/extractors/poro_extractor'
require 'woods/extractors/concern_extractor'

RSpec.describe Woods::Extractors::PoroExtractor, 'standalone module ownership' do
  include_context 'extractor setup'

  before do
    stub_const('StandaloneFixture', Module.new)
    stub_const('ActiveRecord::Base', double('ActiveRecord::Base', descendants: []))
  end

  def load_source(name, source, directory: 'app/models')
    path = create_file("#{directory}/#{name}.rb", source)
    load path
    path
  end

  def units
    described_class.new.extract_all
  end

  it 'discovers an ordinary module singleton method without invoking it' do
    path = load_source('encryption', <<~RUBY)
      module StandaloneFixture::Encryption
        def self.encrypt(value)
          raise 'must never execute'
        end
      end
    RUBY
    unit = units.first
    expect(unit.identifier).to eq('StandaloneFixture::Encryption')
    expect(unit.type).to eq(:poro)
    expect(unit.file_path).to eq(path)
    expect(unit.namespace).to eq('StandaloneFixture')
    expect(unit.metadata).to include(ruby_kind: 'module', class_methods: ['encrypt'], parent_class: nil,
                                     method_count: 1)
  end

  it 'handles class << self without misclassifying the enclosing module as a class' do
    path = load_source('codec', <<~RUBY)
      module StandaloneFixture::Codec
        class << self
          def decode(value)
            raise 'must never execute'
          end
        end
      end
    RUBY
    values = described_class.new.extract_poro_units(path)
    expect(values.map(&:identifier)).to eq(['StandaloneFixture::Codec'])
    expect(values.first.metadata).to include(ruby_kind: 'module', class_methods: ['decode'])
    expect(described_class.new.extract_poro_file(path).identifier).to eq('StandaloneFixture::Codec')
  end

  it 'recognizes module_function and own private instance methods' do
    load_source('functions', <<~RUBY)
      module StandaloneFixture::Functions
        module_function
        def encode(value); raise 'must never execute'; end
        private
        def helper; raise 'must never execute'; end
      end
    RUBY
    expect(units.first.metadata).to include(ruby_kind: 'module', class_methods: ['encode'], public_methods: [],
                                            method_count: 2)
  end

  it 'keeps namespaces empty while extracting nested and compact callable modules' do
    load_source('nested', <<~RUBY)
      module StandaloneFixture
        module Namespace
          module Codec
            def self.decode; end
          end
        end
      end
      module StandaloneFixture::Other
        def call; end
      end
    RUBY
    expect(units.map(&:identifier)).to contain_exactly('StandaloneFixture::Namespace::Codec', 'StandaloneFixture::Other')
  end

  it 'excludes inherited singleton methods, aliases and declarations inside comments or strings' do
    load_source('negative', <<~RUBY)
      module StandaloneFixture::Parent
        def call; end
      end
      module StandaloneFixture::Namespace
        extend StandaloneFixture::Parent
      end
      StandaloneFixture::Alias = StandaloneFixture::Namespace
      module StandaloneFixture::Alias
        def self.alias_only; end
      end
      # module StandaloneFixture::Comment; def self.call; end; end
      TEXT = 'module StandaloneFixture::String; def self.call; end; end'
    RUBY
    expect(units.map(&:identifier)).to eq(['StandaloneFixture::Parent'])
  ensure
    Object.send(:remove_const, :TEXT) if Object.const_defined?(:TEXT, false)
  end

  it 'does not execute application overrides of reflection methods' do
    load_source('reflection', <<~RUBY)
      module StandaloneFixture::Reflection
        def self.call; end
        def self.name; raise 'application name'; end
        def self.singleton_class; raise 'application singleton_class'; end
        def self.public_instance_methods(*); raise 'application reflection'; end
        def self.instance_method(*); raise 'application instance_method'; end
      end
    RUBY
    unit = units.first
    expect(unit.identifier).to eq('StandaloneFixture::Reflection')
    expect(unit.metadata[:class_methods]).to include('call')
  end

  it 'excludes conventional concerns and exact runtime mixin identities while retaining a file sibling' do
    load_source('conventional', <<~RUBY, directory: 'app/models/concerns')
      module StandaloneFixture::Conventional
        def self.call; end
      end
    RUBY
    path = load_source('shared', <<~RUBY)
      module StandaloneFixture::Included
        def normalize; end
        def self.call; end
      end
      module StandaloneFixture::Standalone
        def self.encode; end
      end
    RUBY
    model = Class.new { include StandaloneFixture::Included }
    allow(ActiveRecord::Base).to receive(:descendants).and_return([model])
    values = described_class.new.extract_poro_units(path)
    expect(values.map(&:identifier)).to eq(['StandaloneFixture::Standalone'])
    expect(units.map(&:identifier)).to eq(['StandaloneFixture::Standalone'])
    expect(Woods::Extractors::ConcernExtractor.new.runtime_model_mixins[path]).to include(StandaloneFixture::Included)
  end

  it 'keeps a path-governed module a module unit beside its nested exception class' do
    path = load_source('standalone_fixture/with_helper', <<~RUBY)
      module StandaloneFixture::WithHelper
        class Error < StandardError; end
        def self.call; end
      end
    RUBY
    values = described_class.new.extract_poro_units(path)
    expect(values.map(&:identifier))
      .to contain_exactly('StandaloneFixture::WithHelper', 'StandaloneFixture::WithHelper::Error')
    helper = values.find { |unit| unit.identifier == 'StandaloneFixture::WithHelper' }
    expect(helper.metadata).to include(ruby_kind: 'module', parent_class: nil)
  end

  it 'recomputes module ownership after an includer changes without editing the module' do
    path = load_source('ownership', <<~RUBY)
      module StandaloneFixture::Ownership
        def call; end
      end
    RUBY
    extractor = described_class.new
    expect(extractor.standalone_modules.fetch(path).map(&:identifier)).to eq(['StandaloneFixture::Ownership'])
    model = Class.new { include StandaloneFixture::Ownership }
    allow(ActiveRecord::Base).to receive(:descendants).and_return([model])
    expect(extractor.standalone_modules).to eq({})
    allow(ActiveRecord::Base).to receive(:descendants).and_return([])
    expect(extractor.standalone_modules.fetch(path).map(&:identifier)).to eq(['StandaloneFixture::Ownership'])
  end

  it 'preserves class extraction and returns every eligible module in a shared file' do
    path = load_source('shared_class', <<~RUBY)
      class StandaloneFixture::Value
        def call; end
      end
      module StandaloneFixture::First
        def self.call; end
      end
      module StandaloneFixture::Second
        def self.call; end
      end
    RUBY
    values = described_class.new.extract_poro_units(path)
    expect(values.map(&:identifier)).to eq(%w[StandaloneFixture::Value StandaloneFixture::First StandaloneFixture::Second])
    expect(values.first.metadata).not_to have_key(:ruby_kind)
    expect(described_class.new.extract_poro_file(path).identifier).to eq('StandaloneFixture::Value')
  end

  it 'handles same-file reopenings once but does not claim other-file extension methods' do
    owner = load_source('reopened', <<~RUBY)
      module StandaloneFixture::Reopened
        def self.first; end
      end
      module StandaloneFixture::Reopened
        def self.second; end
      end
    RUBY
    load_source('extension', <<~RUBY)
      module StandaloneFixture::Reopened
        def self.extension; end
      end
    RUBY
    values = units
    expect(values.size).to eq(1)
    expect(values.first.file_path).to eq(owner)
    expect(values.first.metadata[:class_methods]).to eq(%w[first second])
  end

  it 'leaves library-owned modules with their library extractor and excludes unloaded declarations' do
    load_source('library', <<~RUBY, directory: 'lib')
      module StandaloneFixture::Library
        def self.original; end
      end
    RUBY
    load_source('library_extension', <<~RUBY)
      module StandaloneFixture::Library
        def self.extension; end
      end
    RUBY
    create_file('app/models/unloaded.rb', 'module StandaloneFixture::Unloaded; def self.call; end; end')
    expect(units).to eq([])
  end

  it 'does not infer callable ownership from methods introduced only in another file' do
    load_source('empty_owner', 'module StandaloneFixture::EmptyOwner; end')
    load_source('populated_extension', 'module StandaloneFixture::EmptyOwner; def self.call; end; end')
    expect(units).to eq([])
  end

  # Ruby 3.1 can report a constant's location as [false, 0].
  it 'treats a source location without a file name as unowned instead of failing' do
    path = load_source('located', <<~RUBY)
      module StandaloneFixture::Located
        LIMIT = 3
        def self.call = nil
      end
    RUBY
    real = Woods::Extractors::StandaloneModuleDiscovery::CORE_SOURCE
    no_file = Object.new
    no_file.define_singleton_method(:bind) do |scope|
      bound = real.bind(scope)
      Object.new.tap { |call| call.define_singleton_method(:call) { |*args| bound.call(*args) && [false, 0] } }
    end
    stub_const('Woods::Extractors::StandaloneModuleDiscovery::CORE_SOURCE', no_file)

    extractor = described_class.new
    expect(extractor.extract_poro_units(path)).to eq([])
    expect(Woods::SourceInputs::ConsumerErrors.failed?(extractor)).to be(false)
  end

  describe 'module shapes without plain own methods (#673)' do
    before { require 'active_support/concern' }

    def only_unit
      values = units
      expect(values.size).to eq(1)
      values.first
    end

    it 'extracts a concern no model includes as a module unit listing its ClassMethods' do
      load_source('studio/configurable', <<~RUBY)
        module StandaloneFixture::Configurable
          extend ActiveSupport::Concern
          class_methods do
            def configurable(*) = nil
          end
        end
      RUBY
      unit = only_unit
      expect(unit.identifier).to eq('StandaloneFixture::Configurable')
      expect(unit.metadata).to include(ruby_kind: 'module', active_support_concern: true,
                                       class_methods: ['configurable'], public_methods: [], method_count: 1)
    end

    it 'treats an included block as concern behavior even without any method' do
      load_source('stamped', <<~RUBY)
        module StandaloneFixture::Stamped
          extend ActiveSupport::Concern
          included do
            attr_accessor :stamp
          end
        end
      RUBY
      expect(only_unit.metadata).to include(ruby_kind: 'module', active_support_concern: true, method_count: 0)
    end

    it 'keeps singleton methods wrapped by a memoizer defined in another file' do
      load_source('memo', <<~RUBY, directory: 'lib')
        module StandaloneFixture::Memo
          def memoize(name)
            wrapper = Module.new
            wrapper.define_method(name) { |*args| (@memo ||= {})[[name, args]] ||= super(*args) }
            prepend wrapper
            name
          end
        end
      RUBY
      path = load_source('standalone_fixture/preference', <<~RUBY)
        module StandaloneFixture
          module Preference
            module UrlMapper
              class << self
                extend StandaloneFixture::Memo
                memoize def for(path) = Base.new(path)
              end

              class Base
                def initialize(path) = @path = path
              end
            end
          end
        end
      RUBY
      values = described_class.new.extract_poro_units(path)
      expect(values.map(&:identifier)).to contain_exactly('StandaloneFixture::Preference::UrlMapper',
                                                          'StandaloneFixture::Preference::UrlMapper::Base')
      mapper = values.find { |unit| unit.identifier.end_with?('UrlMapper') }
      expect(mapper.metadata).to include(ruby_kind: 'module', class_methods: ['for'])
      base = values.find { |unit| unit.identifier.end_with?('Base') }
      expect(base.metadata).not_to have_key(:ruby_kind)
      expect(base.source_code).to include('def initialize(path)')
      expect(base.source_code).not_to include('memoize def for')
    end

    it 'keeps a singleton method its own file declares but another file redefines' do
      load_source('wrapping', <<~RUBY, directory: 'lib')
        module StandaloneFixture::Wrapping
          def self.wrap(mod, name)
            original = mod.method(name)
            mod.singleton_class.send(:define_method, name) { |*a| original.call(*a) }
          end
        end
      RUBY
      load_source('lookup', <<~RUBY)
        module StandaloneFixture::Lookup
          class << self
            def call(id) = id
          end
          StandaloneFixture::Wrapping.wrap(self, :call)
        end
      RUBY
      expect(only_unit.metadata).to include(ruby_kind: 'module', class_methods: ['call'])
    end

    it 'extracts a constant-only module with its constants in metadata' do
      load_source('email_pattern', <<~RUBY)
        module StandaloneFixture::EmailPattern
          REGEX = /\\A[^@\\s]+@[^@\\s]+\\z/
        end
      RUBY
      unit = only_unit
      expect(unit.identifier).to eq('StandaloneFixture::EmailPattern')
      expect(unit.metadata).to include(ruby_kind: 'module', constants: ['REGEX'], method_count: 0)
    end

    it 'does not count a nested module constant as module content' do
      load_source('billing', <<~RUBY)
        module StandaloneFixture::Billing
          module Inner; end
        end
      RUBY
      expect(units).to eq([])
    end

    it 'makes a bodiless nested exception class in a namespace file a unit, but not a bare class' do
      path = load_source('standalone_fixture/errors', <<~RUBY)
        module StandaloneFixture
          module Errors
            class Missing < StandardError; end
            class Marker; end
          end
        end
      RUBY
      units = described_class.new.extract_poro_units(path)
      expect(units.map(&:identifier)).to eq(['StandaloneFixture::Errors::Missing'])
      expect(units.first.metadata).to include(parent_class: 'StandardError')
    end
  end
end
