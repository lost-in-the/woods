# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'active_support/core_ext/object/blank'
require 'active_support/core_ext/string/inflections'
require 'woods/extractors/poro_extractor'
require 'woods/extractors/lib_extractor'
require 'woods/source_references/registry'

RSpec.describe 'Assigned value class discovery' do
  include_context 'extractor setup'

  before do
    stub_const('ActiveRecord::Base', double('ActiveRecord::Base', descendants: []))
    stub_const('AssignedValues', Module.new)
  end

  def extract_value(relative_path, source)
    path = create_file(relative_path, source)
    load path
    extractor = if relative_path.start_with?('lib/')
                  Woods::Extractors::LibExtractor.new
                else
                  Woods::Extractors::PoroExtractor.new
                end
    method = relative_path.start_with?('lib/') ? :extract_lib_file : :extract_poro_file
    [extractor.public_send(method, path), path]
  end

  %w[Struct.new Data.define].each do |factory|
    next if factory.start_with?('Data') && !defined?(Data)

    %w[module class].each do |wrapper|
      %w[app/models lib].each do |directory|
        it "names the #{factory} child of a #{wrapper} wrapper in #{directory}" do
          AssignedValues.const_set(:Container, wrapper == 'class' ? Class.new : Module.new)
          unit, path = extract_value("#{directory}/assigned_values/container/entry.rb", <<~SOURCE)
            #{wrapper} AssignedValues::Container
              Entry = #{factory}(:value)
            end
          SOURCE
          expect(unit&.identifier).to eq('AssignedValues::Container::Entry')
          expect(unit.file_path).to eq(path)
          expect(unit.metadata[:parent_class]).to be_nil
        end
      end
    end
  end

  it 'retains a callable canonical wrapper alongside its assigned child' do
    path = create_file('app/models/assigned_bundle.rb', <<~SOURCE)
      module AssignedBundle
        Entry = Struct.new(:value)
        def self.call
          raise 'must not run'
        end
      end
    SOURCE
    load path
    units = Woods::Extractors::PoroExtractor.new.extract_poro_units(path)
    expect(units.map(&:identifier)).to contain_exactly('AssignedBundle', 'AssignedBundle::Entry')
  ensure
    Object.send(:remove_const, :AssignedBundle) if Object.const_defined?(:AssignedBundle, false)
  end

  it 'registers a verified assigned child as a reference target without running its methods' do
    unit, path = extract_value('app/models/assigned_values/entry.rb', <<~SOURCE)
      module AssignedValues
        Entry = ::Struct.new(:value) do
          def self.call
            raise 'must not execute'
          end
        end
      end
    SOURCE
    caller_path = create_file('app/models/assigned_caller.rb', <<~SOURCE)
      class AssignedCaller
        def call
          AssignedValues::Entry.call
        end
      end
    SOURCE
    load caller_path
    collector = Woods::SourceReferences::Collector.new
    caller_analysis = collector.call(File.read(caller_path))
    registry = Woods::SourceReferences::Registry.new(
      units: [unit, { type: :poro, identifier: 'AssignedCaller', file_path: caller_path }],
      sources: { path => collector.call(File.read(path)), caller_path => caller_analysis }, root: tmp_dir
    )
    expect(registry.resolve(caller_analysis['references'].first, file_path: caller_path))
      .to eq(type: :poro, target: 'AssignedValues::Entry', via: :code_reference)
  ensure
    Object.send(:remove_const, :AssignedCaller) if Object.const_defined?(:AssignedCaller, false)
  end

  %w[Struct Data].each do |factory|
    next if factory == 'Data' && !defined?(Data)

    it "does not claim a shadowed #{factory} factory even when it returns a real value class" do
      method = factory == 'Struct' ? 'new' : 'define'
      unit, path = extract_value('app/models/assigned_values/entry.rb', <<~SOURCE)
        module AssignedValues
          #{factory} = Class.new do
            def self.#{method}(*)
              ::#{factory}.#{method}(:value)
            end
          end
          Entry = #{factory}.#{method}(:value)
        end
      SOURCE
      expect(unit&.identifier).not_to eq('AssignedValues::Entry')
      stub_const('AssignedCaller', Class.new)
      caller_path = create_file('app/models/assigned_caller.rb', 'class AssignedCaller; AssignedValues::Entry; end')
      collector = Woods::SourceReferences::Collector.new
      caller_analysis = collector.call(File.read(caller_path))
      registry = Woods::SourceReferences::Registry.new(
        units: [{ type: :poro, identifier: 'AssignedValues::Entry', file_path: path },
                { type: :poro, identifier: 'AssignedCaller', file_path: caller_path }],
        sources: { path => collector.call(File.read(path)), caller_path => caller_analysis }, root: tmp_dir
      )
      expect(registry.explain(caller_analysis['references'].first, file_path: caller_path))
        .to eq('status' => 'unresolved', 'reason' => 'target_not_indexed')
    end
  end

  it 'does not invoke overridden runtime reflection or constructor methods during discovery' do
    unit, path = extract_value('app/models/assigned_values/entry.rb', <<~SOURCE)
      module AssignedValues
        Entry = Struct.new(:value)
        class << Entry
          def ancestors; raise 'must not run ancestors'; end
          def name; raise 'must not run name'; end
          def singleton_class; raise 'must not run singleton_class'; end
        end
        def self.const_source_location(*); raise 'must not run source lookup'; end
      end
    SOURCE
    expect(unit.identifier).to eq('AssignedValues::Entry')
    expect(Woods::Extractors::PoroExtractor.new.extract_poro_file(path).identifier).to eq(unit.identifier)
  end

  it 'requires the assignment to own the canonical loaded class at this exact file' do
    original = create_file('app/models/assigned_values/entry.rb', <<~SOURCE)
      module AssignedValues
        Entry = Struct.new(:value)
      end
    SOURCE
    load original
    copied = create_file('app/models/assigned_values/copied.rb', File.read(original))
    expect(Woods::Extractors::PoroExtractor.new.extract_poro_file(copied)).to be_nil
  end

  it 'does not mistake an alias, arbitrary factory, or constructor result instance for a value class' do
    %w[Entry Alias Dynamic Instance].each do |name|
      AssignedValues.send(:remove_const, name) if AssignedValues.const_defined?(name, false)
    end
    path = create_file('app/models/assigned_values/entry.rb', <<~SOURCE)
      module AssignedValues
        Entry = Struct.new(:value)
        Alias = Entry
        Dynamic = Class.new
        Instance = Struct.new(:value).new(1)
      end
    SOURCE
    load path
    analysis = Woods::SourceReferences::Collector.new.call(File.read(path))
    declarations = analysis['declarations'].select { |record| record['constructor'] }
    expect(declarations.map { |record| record['owner'] }).to eq(['AssignedValues::Entry'])
    expect(Woods::Extractors::PoroExtractor.new.extract_poro_file(path).identifier).to eq('AssignedValues::Entry')
  end

  it 'does not replace a canonical ordinary class with its nested value-class helper' do
    path = create_file('app/models/assigned_values/ordinary.rb', <<~SOURCE)
      class AssignedValues::Ordinary
        Nested = Struct.new(:value)
      end
    SOURCE
    load path
    expect(Woods::Extractors::PoroExtractor.new.extract_poro_file(path).identifier).to eq('AssignedValues::Ordinary')
  end
  %w[app/models lib].each do |directory|
    it "discovers an assigned child inside a native wrapper with no Ruby source in #{directory}" do
      unit, path = extract_value("#{directory}/native_values.rb", <<~SOURCE)
        class Struct
          WoodsAssignedProbe = Struct.new(:value)
        end
      SOURCE
      expect(unit&.identifier).to eq('Struct::WoodsAssignedProbe')
      analysis = Woods::SourceReferences::Collector.new.call(File.read(path))
      registry = Woods::SourceReferences::Registry.new(units: [unit], sources: { path => analysis }, root: tmp_dir)
      expect(registry.owner?('Struct::WoodsAssignedProbe', file_path: path)).to be(true)
    ensure
      Struct.send(:remove_const, :WoodsAssignedProbe) if Struct.const_defined?(:WoodsAssignedProbe, false)
    end
  end

  it 'preserves a top-level named Struct lookup without admitting its alias as a reference target' do
    unit, path = extract_value('app/models/assigned_named_value.rb', <<~SOURCE)
      AssignedNamedValue = Struct.new('AssignedNamedUnderlying', :value)
    SOURCE
    expect(unit&.identifier).to eq('AssignedNamedValue')
    analysis = Woods::SourceReferences::Collector.new.call(File.read(path))
    registry = Woods::SourceReferences::Registry.new(units: [unit], sources: { path => analysis }, root: tmp_dir)
    expect(registry.owner?('AssignedNamedValue', file_path: path)).to be_falsey
  ensure
    Object.send(:remove_const, :AssignedNamedValue) if Object.const_defined?(:AssignedNamedValue, false)
    Struct.send(:remove_const, :AssignedNamedUnderlying) if Struct.const_defined?(:AssignedNamedUnderlying, false)
  end

  it 'preserves a canonical callable library module instead of replacing it with its value helper' do
    unit, = extract_value('lib/assigned_library_bundle.rb', <<~SOURCE)
      module AssignedLibraryBundle
        Entry = Struct.new(:value)
        def self.call
          raise 'must not run'
        end
      end
    SOURCE
    expect(unit&.identifier).to eq('AssignedLibraryBundle')
  ensure
    Object.send(:remove_const, :AssignedLibraryBundle) if Object.const_defined?(:AssignedLibraryBundle, false)
  end

  it 'preserves a source-owned callable library module even when its name differs from the path convention' do
    unit, = extract_value('lib/irregular_name.rb', <<~SOURCE)
      module AssignedOddLibrary
        Entry = Struct.new(:value)
        def self.call
          raise 'must not run'
        end
      end
    SOURCE
    expect(unit&.identifier).to eq('AssignedOddLibrary')
  ensure
    Object.send(:remove_const, :AssignedOddLibrary) if Object.const_defined?(:AssignedOddLibrary, false)
  end

  it 'promotes a child when its file first establishes an otherwise empty library namespace' do
    unit, = extract_value('lib/assigned_first_namespace/entry.rb', <<~SOURCE)
      module AssignedFirstNamespace
        Entry = Struct.new(:value) do
          def self.call
            raise 'a child method is not a wrapper method'
          end
        end
      end
    SOURCE
    expect(unit&.identifier).to eq('AssignedFirstNamespace::Entry')
  ensure
    Object.send(:remove_const, :AssignedFirstNamespace) if Object.const_defined?(:AssignedFirstNamespace, false)
  end
end
