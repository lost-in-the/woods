# frozen_string_literal: true

require 'spec_helper'
require 'codebase_index/ast/node'

RSpec.describe CodebaseIndex::Ast::Node do
  describe 'struct initialization' do
    it 'creates a node with keyword arguments' do
      node = described_class.new(
        type: :send,
        children: [],
        line: 10,
        receiver: 'User',
        method_name: 'find',
        arguments: ['id']
      )

      expect(node.type).to eq(:send)
      expect(node.children).to eq([])
      expect(node.line).to eq(10)
      expect(node.receiver).to eq('User')
      expect(node.method_name).to eq('find')
      expect(node.arguments).to eq(['id'])
    end

    it 'defaults optional fields to nil' do
      node = described_class.new(type: :begin, children: [], line: 1)

      expect(node.receiver).to be_nil
      expect(node.method_name).to be_nil
      expect(node.arguments).to be_nil
      expect(node.source).to be_nil
      expect(node.end_line).to be_nil
    end

    it 'stores source text' do
      node = described_class.new(type: :if, children: [], line: 5, source: 'x > 0')

      expect(node.source).to eq('x > 0')
    end

    it 'stores end_line' do
      node = described_class.new(type: :def, children: [], line: 5, end_line: 10, method_name: 'foo')

      expect(node.end_line).to eq(10)
    end
  end

  describe '#find_all' do
    it 'finds all descendant nodes matching a type' do
      send1 = described_class.new(type: :send, children: [], line: 1, method_name: 'foo')
      send2 = described_class.new(type: :send, children: [], line: 2, method_name: 'bar')
      def_node = described_class.new(type: :def, children: [send1], line: 1, method_name: 'test')
      root = described_class.new(type: :begin, children: [def_node, send2], line: 1)

      results = root.find_all(:send)

      expect(results.size).to eq(2)
      expect(results.map(&:method_name)).to contain_exactly('foo', 'bar')
    end

    it 'returns empty array when no matches' do
      node = described_class.new(type: :begin, children: [], line: 1)

      expect(node.find_all(:send)).to eq([])
    end

    it 'includes the root node if it matches' do
      node = described_class.new(type: :send, children: [], line: 1, method_name: 'foo')

      expect(node.find_all(:send)).to eq([node])
    end

    it 'skips non-Node children' do
      child = described_class.new(type: :send, children: [], line: 2, method_name: 'bar')
      root = described_class.new(type: :begin, children: ['string', nil, child, 42], line: 1)

      results = root.find_all(:send)

      expect(results).to eq([child])
    end
  end

  describe '#find_first' do
    it 'finds the first matching node depth-first' do
      deep = described_class.new(type: :send, children: [], line: 3, method_name: 'deep')
      mid = described_class.new(type: :def, children: [deep], line: 2, method_name: 'mid')
      shallow = described_class.new(type: :send, children: [], line: 4, method_name: 'shallow')
      root = described_class.new(type: :begin, children: [mid, shallow], line: 1)

      result = root.find_first(:send)

      expect(result.method_name).to eq('deep')
    end

    it 'returns self if root matches' do
      node = described_class.new(type: :send, children: [], line: 1, method_name: 'self')

      expect(node.find_first(:send)).to eq(node)
    end

    it 'returns nil when no match' do
      node = described_class.new(type: :begin, children: [], line: 1)

      expect(node.find_first(:send)).to be_nil
    end
  end

  describe '#to_source' do
    it 'returns the source field if present' do
      node = described_class.new(type: :if, children: [], line: 1, source: 'checkout.persisted?')

      expect(node.to_source).to eq('checkout.persisted?')
    end

    it 'reconstructs send nodes' do
      node = described_class.new(type: :send, children: [], line: 1, receiver: 'User', method_name: 'find')

      expect(node.to_source).to eq('User.find')
    end

    it 'reconstructs send nodes without receiver' do
      node = described_class.new(type: :send, children: [], line: 1, method_name: 'puts')

      expect(node.to_source).to eq('puts')
    end

    it 'reconstructs const nodes' do
      node = described_class.new(type: :const, children: [], line: 1, receiver: 'CodebaseIndex',
                                 method_name: 'Extractor')

      expect(node.to_source).to eq('CodebaseIndex::Extractor')
    end

    it 'reconstructs def nodes' do
      node = described_class.new(type: :def, children: [], line: 1, method_name: 'create')

      expect(node.to_source).to eq('def create')
    end

    it 'falls back to type string for other nodes' do
      node = described_class.new(type: :begin, children: [], line: 1)

      expect(node.to_source).to eq('begin')
    end
  end
end
