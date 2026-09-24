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

  it 'never emits a second class-shaped unit for a path-governed module containing a helper class' do
    path = load_source('standalone_fixture/with_helper', <<~RUBY)
      module StandaloneFixture::WithHelper
        class Error < StandardError; end
        def self.call; end
      end
    RUBY
    values = described_class.new.extract_poro_units(path)
    expect(values.map(&:identifier)).to eq(['StandaloneFixture::WithHelper'])
    expect(values.first.metadata).to include(ruby_kind: 'module', parent_class: nil)
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
end
