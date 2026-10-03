# frozen_string_literal: true

require 'prism'

module Woods
  module Extractors
    # Finds the calls in component source that can render another component.
    #
    # A syntax-tree walk, so a comment, a string, or a heredoc cannot supply a
    # call, and each candidate carries the lexical nesting of its call site
    # (`Module.nesting`, innermost first). Naming the target is the job of
    # {RenderTargetResolver}; this class only reports what the source says.
    #
    # Four shapes are reported:
    #
    # * +:constant+: `render Widget.new`, `render Widget.with_collection(rows)`,
    #   `render Widget`
    # * +:kit+: `Header(title: "x")`, a capitalized call on the component itself
    # * +:kit_path+: `Ui::Header(title: "x")`, the same call on a named module
    # * +:yielded+: `menu.NavItem("a")`, the same call on a block argument
    #
    # A lowercase call (`form_with`, `t`, `partial`) is never a candidate.
    #
    # @example
    #   RenderCallScan.call("class Page\n  def view_template = render(Widget.new)\nend")
    #   # => [#<struct kind=:constant, name="Widget", nesting=["Page"]>]
    #
    class RenderCallScan < Prism::Visitor
      # One call that may render a component.
      #
      # @!attribute kind
      #   @return [Symbol] +:constant+, +:kit+, +:kit_path+ or +:yielded+
      # @!attribute name
      #   @return [String] the constant path or method name as written
      # @!attribute nesting
      #   @return [Array<String>] qualified lexical scopes, innermost first
      Candidate = Struct.new(:kind, :name, :nesting, keyword_init: true)

      # Class methods that build what `render` receives.
      FACTORIES = %i[new with_collection].freeze

      CAPITALIZED = /\A[[:upper:]]/

      # @param source [String] Ruby source of one component file
      # @return [Array<Candidate>] candidates in source order
      def self.call(source)
        scan = new
        Prism.parse(source).value.accept(scan)
        scan.candidates
      rescue SystemStackError
        # Source nested past what a recursive walk can follow names no
        # component a reader could act on.
        []
      end

      # @return [Array<Candidate>]
      attr_reader :candidates

      def initialize
        super
        @candidates = []
        @nesting = []
      end

      # @param node [Prism::ClassNode]
      # @return [void]
      def visit_class_node(node)
        within(node.constant_path) { super }
      end

      # @param node [Prism::ModuleNode]
      # @return [void]
      def visit_module_node(node)
        within(node.constant_path) { super }
      end

      # @param node [Prism::CallNode]
      # @return [void]
      def visit_call_node(node)
        if node.name == :render
          record_render(node)
        elsif CAPITALIZED.match?(node.name.to_s)
          record_capitalized_call(node)
        end
        super
      end

      private

      def within(constant_path)
        name = constant_name(constant_path)
        return yield unless name

        qualified = name.start_with?('::') || @nesting.empty? ? name.delete_prefix('::') : "#{@nesting.first}::#{name}"
        @nesting.unshift(qualified)
        begin
          yield
        ensure
          @nesting.shift
        end
      end

      def record_render(node)
        argument = node.arguments&.arguments&.first
        name = constant_name(argument) || factory_receiver(argument)
        add(:constant, name) if name
      end

      # `Widget.new(1).with_content("x")` still renders Widget: follow the
      # receiver chain down to the factory call on a constant.
      def factory_receiver(node)
        while node.is_a?(Prism::CallNode)
          name = constant_name(node.receiver)
          return (name if FACTORIES.include?(node.name)) if name

          node = node.receiver
        end
        nil
      end

      def record_capitalized_call(node)
        receiver = node.receiver
        if receiver.nil? || receiver.is_a?(Prism::SelfNode)
          add(:kit, node.name.to_s)
        elsif (path = constant_name(receiver))
          add(:kit_path, "#{path}::#{node.name}")
        else
          add(:yielded, node.name.to_s)
        end
      end

      def add(kind, name)
        @candidates << Candidate.new(kind: kind, name: name, nesting: @nesting.dup)
      end

      # @return [String, nil] nil for anything but a literal constant path
      def constant_name(node)
        case node
        when Prism::ConstantReadNode then node.name.to_s
        when Prism::ConstantPathNode then node.full_name
        end
      rescue StandardError
        # A path with a dynamic segment (`klass::Widget`) names no constant.
        nil
      end
    end
  end
end
