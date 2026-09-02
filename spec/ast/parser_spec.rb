# frozen_string_literal: true

require 'spec_helper'
require 'woods/ast/parser'

RSpec.describe Woods::Ast::Parser do
  subject(:parser) { described_class.new }

  describe '#parse' do
    it 'parses valid Ruby source' do
      root = parser.parse('x = 1')

      expect(root).to be_a(Woods::Ast::Node)
    end

    it 'raises ExtractionError for invalid syntax' do
      expect { parser.parse('def foo(') }.to raise_error(Woods::ExtractionError)
    end

    it 'parses multi-class files' do
      source = <<~RUBY
        class Foo
        end

        class Bar
        end
      RUBY

      root = parser.parse(source)
      classes = root.find_all(:class)

      expect(classes.size).to eq(2)
      expect(classes.map(&:method_name)).to contain_exactly('Foo', 'Bar')
    end
  end

  describe '#prism_available?' do
    it 'returns a boolean' do
      expect(parser.prism_available?).to be(true).or be(false)
    end
  end

  # ── Structural Contract Tests ──────────────────────────────────────────
  # These contracts are depended on by L1 agents (ruby-analyzer, flow-assembler, backlog-cleanup).

  describe 'structural contracts' do
    describe 'send nodes' do
      it 'has receiver and method_name populated' do
        root = parser.parse('User.find(1)')
        send_node = root.find_first(:send)

        expect(send_node).not_to be_nil
        expect(send_node.receiver).to eq('User')
        expect(send_node.method_name).to eq('find')
      end

      it 'has nil receiver for bare method calls' do
        root = parser.parse("puts 'hello'")
        send_node = root.find_first(:send)

        expect(send_node.receiver).to be_nil
        expect(send_node.method_name).to eq('puts')
      end

      it 'captures arguments as strings' do
        root = parser.parse('render json: data, status: :ok')
        send_node = root.find_first(:send)

        expect(send_node.arguments).to be_an(Array)
        expect(send_node.arguments).not_to be_empty
      end
    end

    describe 'def nodes' do
      it 'has method_name populated' do
        root = parser.parse('def create; end')
        def_node = root.find_first(:def)

        expect(def_node).not_to be_nil
        expect(def_node.method_name).to eq('create')
      end

      it 'has end_line populated' do
        source = <<~RUBY
          def create
            x = 1
          end
        RUBY

        root = parser.parse(source)
        def_node = root.find_first(:def)

        expect(def_node.end_line).to eq(3)
      end

      it 'has source populated with full method text' do
        source = <<~RUBY
          def create
            x = 1
          end
        RUBY

        root = parser.parse(source)
        def_node = root.find_first(:def)

        expect(def_node.source).to include('def create')
        expect(def_node.source).to include('end')
      end
    end

    describe 'defs nodes (class methods)' do
      it 'has method_name and receiver populated' do
        root = parser.parse('def self.build; end')
        defs_node = root.find_first(:defs)

        expect(defs_node).not_to be_nil
        expect(defs_node.method_name).to eq('build')
        expect(defs_node.receiver).to eq('self')
      end
    end

    describe 'class nodes' do
      it 'has method_name for constant name' do
        root = parser.parse('class Foo; end')
        class_node = root.find_first(:class)

        expect(class_node).not_to be_nil
        expect(class_node.method_name).to eq('Foo')
      end

      it 'handles namespaced classes' do
        root = parser.parse('class A::B::C; end')
        class_node = root.find_first(:class)

        expect(class_node.method_name).to eq('A::B::C')
      end

      it 'has end_line populated' do
        source = <<~RUBY
          class Foo
            def bar; end
          end
        RUBY

        root = parser.parse(source)
        class_node = root.find_first(:class)

        expect(class_node.end_line).to eq(3)
      end
    end

    describe 'module nodes' do
      it 'has method_name for module name' do
        root = parser.parse('module MyModule; end')
        mod_node = root.find_first(:module)

        expect(mod_node).not_to be_nil
        expect(mod_node.method_name).to eq('MyModule')
      end
    end

    describe 'const nodes' do
      it 'uses method_name for constant name and receiver for parent' do
        root = parser.parse('Woods::Extractor')
        const_nodes = root.find_all(:const)

        # The top-level const path node
        path_node = const_nodes.find { |n| n.method_name == 'Extractor' }

        expect(path_node).not_to be_nil
        expect(path_node.receiver).to eq('Woods')
        expect(path_node.method_name).to eq('Extractor')
      end

      it 'handles simple constants' do
        root = parser.parse('Foo')
        const_node = root.find_first(:const)

        expect(const_node.method_name).to eq('Foo')
        expect(const_node.receiver).to be_nil
      end
    end

    describe 'block nodes' do
      it 'has send node as first child and body as second' do
        source = <<~RUBY
          items.each do |item|
            process(item)
          end
        RUBY

        root = parser.parse(source)
        block_node = root.find_first(:block)

        expect(block_node).not_to be_nil
        expect(block_node.children.size).to be >= 1

        send_child = block_node.children[0]
        expect(send_child.type).to eq(:send)
        expect(send_child.method_name).to eq('each')
      end

      it 'handles blocks with brace syntax' do
        root = parser.parse('items.map { |i| i.name }')
        block_node = root.find_first(:block)

        expect(block_node).not_to be_nil
        send_child = block_node.children[0]
        expect(send_child.type).to eq(:send)
        expect(send_child.method_name).to eq('map')
      end
    end

    describe 'if nodes' do
      it 'has condition, then-body, else-body as children' do
        source = <<~RUBY
          if x > 0
            positive
          else
            negative
          end
        RUBY

        root = parser.parse(source)
        if_node = root.find_first(:if)

        expect(if_node).not_to be_nil
        expect(if_node.children.size).to be >= 2

        # First child is condition
        condition = if_node.children[0]
        expect(condition).to be_a(Woods::Ast::Node)
      end

      it 'handles if without else' do
        source = <<~RUBY
          if x > 0
            positive
          end
        RUBY

        root = parser.parse(source)
        if_node = root.find_first(:if)

        expect(if_node).not_to be_nil
        # Should have at least condition and then-body
        expect(if_node.children.size).to be >= 2
      end
    end

    describe 'call arguments' do
      # EXTB-5. Call arguments were flattened to source text and never became
      # children, so anything nested inside them — most visibly a `private def`
      # body — was invisible to every tree walker.
      it 'converts a def passed as an argument into a child node' do
        source = <<~RUBY
          class Foo
            def visible
              Public.call
            end

            private def hidden
              Secret.reveal
            end
          end
        RUBY

        root = parser.parse(source)

        expect(root.find_all(:def).map(&:method_name)).to include('hidden')
      end

      it 'converts call arguments into children so nested calls are walkable' do
        root = parser.parse('foo(Bar.baz)')

        nested = root.find_all(:send).find { |n| n.method_name == 'baz' }

        expect(nested).not_to be_nil
        expect(nested.receiver).to eq('Bar')
      end

      it 'keeps the arguments text field alongside the argument children' do
        root = parser.parse('foo(Bar.baz)')

        outer = root.find_all(:send).find { |n| n.method_name == 'foo' }

        expect(outer.arguments).to eq(['Bar.baz'])
      end
    end

    describe 'unless nodes' do
      # EXTB-4. `Prism::UnlessNode` shares `convert_prism_if`; its body runs
      # when the predicate is *false*, so it belongs in the else slot.
      it 'places the unless body in the else slot and the else clause in the then slot' do
        source = <<~RUBY
          unless admin?
            audit
          else
            charge
          end
        RUBY

        root = parser.parse(source)
        if_node = root.find_first(:if)

        expect(if_node.source).to eq('admin?')
        expect(if_node.children[1].find_first(:send).method_name).to eq('charge')
        expect(if_node.children[2].find_first(:send).method_name).to eq('audit')
      end

      it 'leaves a nil then hole for the modifier form' do
        root = parser.parse('charge unless admin?')
        if_node = root.find_first(:if)

        expect(if_node.children[1]).to be_nil
        expect(if_node.children[2].find_first(:send).method_name).to eq('charge')
      end
    end

    describe 'case nodes' do
      # EXTB-15. The predicate slot is positional: a predicate-less `case`
      # keeps a nil hole so consumers can still `drop(1)` for the branches.
      it 'keeps a nil predicate hole when the case has no predicate' do
        source = <<~RUBY
          case
          when urgent?
            escalate
          else
            ignore
          end
        RUBY

        root = parser.parse(source)
        case_node = root.find_first(:case)

        expect(case_node).not_to be_nil
        expect(case_node.children[0]).to be_nil
        expect(case_node.children.drop(1).size).to eq(2)
      end

      it 'keeps the predicate in the first slot when present' do
        source = <<~RUBY
          case role
          when :admin
            escalate
          end
        RUBY

        root = parser.parse(source)
        case_node = root.find_first(:case)

        expect(case_node.children[0]).to be_a(Woods::Ast::Node)
      end
    end

    describe 'line numbers' do
      it 'tracks correct 1-based line numbers' do
        source = <<~RUBY
          class Foo
            def bar
              baz
            end
          end
        RUBY

        root = parser.parse(source)
        class_node = root.find_first(:class)
        def_node = root.find_first(:def)
        send_node = root.find_first(:send)

        expect(class_node.line).to eq(1)
        expect(def_node.line).to eq(2)
        expect(send_node.line).to eq(3)
      end
    end
  end
end
