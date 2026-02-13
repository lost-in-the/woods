# frozen_string_literal: true

require 'spec_helper'
require 'codebase_index/ast/parser'
require 'codebase_index/ast/constant_resolver'

RSpec.describe CodebaseIndex::Ast::ConstantResolver do
  let(:parser) { CodebaseIndex::Ast::Parser.new }

  describe '#resolve' do
    context 'with no known constants' do
      subject(:resolver) { described_class.new }

      it 'resolves simple constants' do
        root = parser.parse("Foo")
        const_node = root.find_first(:const)

        expect(resolver.resolve(const_node)).to eq('Foo')
      end

      it 'resolves nested constants' do
        root = parser.parse("A::B::C")
        const_node = root.find_first(:const)

        expect(resolver.resolve(const_node)).to eq('A::B::C')
      end

      it 'returns nil for non-const nodes' do
        node = CodebaseIndex::Ast::Node.new(type: :send, children: [], line: 1)

        expect(resolver.resolve(node)).to be_nil
      end
    end

    context 'with known constants' do
      subject(:resolver) do
        described_class.new(known_constants: [
          'CodebaseIndex::Extractor',
          'CodebaseIndex::ExtractedUnit',
          'CodebaseIndex::Ast::Parser',
          'Foo'
        ])
      end

      it 'resolves exact matches' do
        root = parser.parse("Foo")
        const_node = root.find_first(:const)

        expect(resolver.resolve(const_node)).to eq('Foo')
      end

      it 'resolves with namespace context' do
        root = parser.parse("Extractor")
        const_node = root.find_first(:const)

        expect(resolver.resolve(const_node, namespace: 'CodebaseIndex')).to eq('CodebaseIndex::Extractor')
      end

      it 'resolves nested namespace context' do
        root = parser.parse("Parser")
        const_node = root.find_first(:const)

        expect(resolver.resolve(const_node, namespace: 'CodebaseIndex::Ast')).to eq('CodebaseIndex::Ast::Parser')
      end

      it 'returns nil for unknown constants' do
        root = parser.parse("Unknown")
        const_node = root.find_first(:const)

        expect(resolver.resolve(const_node)).to be_nil
      end

      it 'resolves fully qualified paths directly' do
        root = parser.parse("CodebaseIndex::Extractor")
        # Find the outer-most const node
        const_nodes = root.find_all(:const)
        path_node = const_nodes.find { |n| n.receiver }

        expect(resolver.resolve(path_node)).to eq('CodebaseIndex::Extractor')
      end
    end
  end

  describe '#resolve_all' do
    subject(:resolver) do
      described_class.new(known_constants: %w[User UserService])
    end

    it 'finds all constant references in a tree' do
      source = <<~RUBY
        class Foo
          User.find(1)
          UserService.call
        end
      RUBY

      root = parser.parse(source)
      results = resolver.resolve_all(root)

      names = results.map { |r| r[:name] }
      expect(names).to include('User')
      expect(names).to include('UserService')
      expect(names).to include('Foo')
    end

    it 'includes line numbers' do
      source = <<~RUBY
        User.find(1)
      RUBY

      root = parser.parse(source)
      results = resolver.resolve_all(root)

      user_ref = results.find { |r| r[:name] == 'User' }
      expect(user_ref[:line]).to eq(1)
    end

    it 'deduplicates by name and line' do
      source = "User.find(User.first)"

      root = parser.parse(source)
      results = resolver.resolve_all(root)

      user_refs = results.select { |r| r[:name] == 'User' }
      expect(user_refs.size).to eq(1)
    end
  end
end
