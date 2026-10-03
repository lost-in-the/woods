# frozen_string_literal: true

require 'spec_helper'
require 'timeout'
require 'woods/extractors/constant_paths'

RSpec.describe Woods::Extractors::ConstantPaths do
  describe '.normalize' do
    it 'strips a leading :: from a constant path' do
      expect(described_class.normalize('::Ledger::Entry')).to eq('Ledger::Entry')
    end

    it 'leaves a relative path and nil untouched' do
      expect(described_class.normalize('Ledger::Entry')).to eq('Ledger::Entry')
      expect(described_class.normalize(nil)).to be_nil
    end
  end

  describe '.mixin_owner' do
    it 'names the module that owns a ClassMethods mixin' do
      expect(described_class.mixin_owner('Mixin::Auditable::ClassMethods')).to eq('Mixin::Auditable')
    end

    it 'leaves every other name untouched, including a bare ClassMethods' do
      expect(described_class.mixin_owner('Mixin::Auditable')).to eq('Mixin::Auditable')
      expect(described_class.mixin_owner('ClassMethods')).to eq('ClassMethods')
    end
  end

  describe '.references' do
    def paths(source)
      described_class.references(source).map(&:path)
    end

    it 'records a compact path whole, never its last segment' do
      refs = described_class.references(<<~RUBY)
        module Mutations
          class ShipWidget
            def resolve(ctx)
              Resolvers::Ledger::Create.new(ctx)
            end
          end
        end
      RUBY

      expect(refs.map(&:path)).to eq(['Resolvers::Ledger::Create'])
      expect(refs.first.call).to eq('new')
      expect(refs.first.nesting).to eq(['Mutations::ShipWidget', 'Mutations'])
    end

    it 'keeps the leading :: of a top-level path as written' do
      expect(paths("class Widget\n  X = ::Ledger::Entry\nend\n")).to eq(['::Ledger::Entry'])
    end

    it 'records the nesting a compact declaration really opens' do
      refs = described_class.references("class Types::WidgetType < Types::BaseObject\n  Shipment\nend\n")

      expect(refs.map { |ref| [ref.path, ref.nesting] }).to eq(
        [['Types::BaseObject', []], ['Shipment', ['Types::WidgetType']]]
      )
    end

    it 'records the keyword a constant is passed under' do
      refs = described_class.references("class Q\n  field :w, resolver: Resolvers::Widgets\nend\n")

      expect(refs.map { |ref| [ref.path, ref.keyword] }).to eq([%w[Resolvers::Widgets resolver]])
    end

    it 'records a string literal that spells a namespaced constant' do
      refs = described_class.references(%(class Q\n  field :w, "Types::WidgetType"\n  x = "hello"\nend\n))

      expect(refs.map { |ref| [ref.path, ref.literal] }).to eq([['Types::WidgetType', true]])
    end

    it 'ignores comments, declaration names and assignment targets' do
      expect(paths(<<~RUBY)).to eq(['Shipment'])
        # Types::Ghost.new
        module Types
          class WidgetType
            LIMIT = 5
            Types::CACHE = Shipment
          end
        end
      RUBY
    end

    it 'skips a path with a dynamic parent' do
      expect(paths("class Q\n  def x\n    widget::Entry.new\n  end\nend\n")).to eq([])
    end

    context 'when the source does not parse' do
      it 'falls back to a token pass that still records whole paths' do
        refs = described_class.references(<<~RUBY)
          class Broken
            def x
              Resolvers::Ledger::Create.new(1)
              field :w, resolver: Resolvers::Widgets # Types::Ghost
              widget::Entry
        RUBY

        expect(refs.map { |ref| [ref.path, ref.call, ref.keyword] }).to eq(
          [['Broken', nil, nil], ['Resolvers::Ledger::Create', 'new', nil], ['Resolvers::Widgets', nil, 'resolver']]
        )
        expect(refs.map(&:nesting).uniq).to eq([[]])
      end

      # The fallback regexes run over uncontrolled, unparseable source.
      def within_budget(&block)
        if Regexp.respond_to?(:timeout=)
          previous = Regexp.timeout
          Regexp.timeout = 1
          begin
            block.call
          ensure
            Regexp.timeout = previous
          end
        else
          Timeout.timeout(5, &block)
        end
      end

      it 'stays linear on 50k repeated chain segments' do
        source = "class Broken\n#{'A::' * 50_000}\n"
        expect { within_budget { described_class.references(source) } }.not_to raise_error
      end

      it 'stays linear on 10k near-matches' do
        dynamic = 'a::B ' * 10_000
        keywords = 'k: ' * 10_000
        words = "#{'A' * 50_000} #{':' * 50_000}"
        source = "class Broken\n#{dynamic}\n#{keywords}\n#{words}\n"
        expect { within_budget { described_class.references(source) } }.not_to raise_error
      end
    end
  end

  describe '.resolve' do
    before do
      stub_const('Depot', Module.new)
      stub_const('Depot::Crate', Class.new)
      stub_const('Depot::Loader', Class.new)
      stub_const('Crate', Class.new)
      stub_const('Depot::LIMIT', 5)
      stub_const('Depot::Box', Depot::Crate)
    end

    it 'resolves a relative path from the innermost nesting outward' do
      resolution = described_class.resolve('Crate', ['Depot::Loader', 'Depot'])

      expect(resolution.target).to eq('Depot::Crate')
      expect(resolution.status).to eq(:resolved)
    end

    it 'resolves at the top level when no nesting declares it' do
      expect(described_class.resolve('Crate', []).target).to eq('Crate')
    end

    it 'strips the leading :: and resolves from the top level only' do
      expect(described_class.resolve('::Crate', ['Depot::Loader', 'Depot']).target).to eq('Crate')
    end

    it 'keeps the written path, never a last segment, when nothing resolves' do
      resolution = described_class.resolve('Missing::Ledger::Create', ['Depot'])

      expect(resolution.target).to eq('Missing::Ledger::Create')
      expect(resolution.status).to eq(:unresolved)
    end

    it 'resolves an absolute-looking path even when the nesting is not loaded' do
      expect(described_class.resolve('Depot::Crate', ['Unloaded::Scope']).target).to eq('Depot::Crate')
    end

    it 'follows an alias to the constant it names' do
      expect(described_class.resolve('Depot::Box', []).target).to eq('Depot::Crate')
    end

    it 'reports a constant that is not a class or module' do
      expect(described_class.resolve('Depot::LIMIT', []).status).to eq(:value)
    end

    it 'reports where a resolved constant is defined' do
      expect(described_class.resolve('Woods::Extractors::ConstantPaths', []).source_file)
        .to end_with('lib/woods/extractors/constant_paths.rb')
      expect(described_class.resolve('String', []).source_file).to be_nil
    end
  end
end
