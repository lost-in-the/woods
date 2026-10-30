# frozen_string_literal: true

require 'prism'
require_relative 'rake_body_facts'

module Woods
  module Extractors
    # Reads the Rake DSL out of one source file with Prism. Nothing is run.
    #
    # It finds task definitions (+task+, +multitask+, +file+, +directory+,
    # +rule+, and task classes such as +RSpec::Core::RakeTask.new+), the
    # namespaces and conditionals around them, +desc+ text, +enhance+ calls,
    # and the method and constant definitions a support file contributes.
    #
    # A name, namespace, prerequisite list or description that is computed
    # rather than written out is reported as unknown (+nil+, or a +_literal+
    # flag set to false), never guessed. The caller decides whether the loaded
    # Rake application can fill it in.
    #
    # Task bodies are summarized by {RakeBodyFacts} and are not searched for
    # further definitions: a task defined while another runs does not exist
    # until that run.
    #
    # @example
    #   result = RakeSourceParser.parse("namespace :db do\n  task seed: :environment\nend\n")
    #   result.definitions.first.values_at(:full_name, :prerequisites)
    #   # => ["db:seed", ["environment"]]
    class RakeSourceParser
      # @!attribute definitions
      #   @return [Array<Hash>] one per defining call, in source order
      # @!attribute enhancements
      #   @return [Array<Hash>] one per +enhance+ call with a literal target
      # @!attribute method_definitions
      #   @return [Array<Hash>] +{ name:, line:, facts: }+ per +def+
      # @!attribute constants
      #   @return [Array<String>] modules and classes the file opens
      # @!attribute facts
      #   @return [Hash] {RakeBodyFacts.collect} over the whole file
      Result = Struct.new(:definitions, :enhancements, :method_definitions, :constants, :facts, keyword_init: true)

      Context = Struct.new(:namespace, :conditions, :modules)

      # DSL method => definition kind.
      DEFINERS = {
        task: :task, multitask: :multitask, file: :file, file_create: :file, directory: :directory, rule: :rule
      }.freeze

      # Kinds Rake never scopes under a namespace.
      UNSCOPED_KINDS = %i[file directory rule].freeze

      # The task a task class defines when `.new` is given no name.
      TASK_CLASS_DEFAULTS = {
        'RSpec::Core::RakeTask' => 'spec',
        'RuboCop::RakeTask' => 'rubocop',
        'Rake::TestTask' => 'test',
        'YARD::Rake::YardocTask' => 'yard',
        'Cucumber::Rake::Task' => 'cucumber',
        'RDoc::Task' => 'rdoc'
      }.freeze

      TASK_CLASS_SUFFIX = 'Task'

      # Hash keys in a task signature that are options, not the task name.
      OPTION_KEYS = %w[order_only].freeze

      CONDITION_LIMIT = 200

      # @param source [String] Ruby source of a rake file or a support file
      # @return [Result]
      def self.parse(source)
        new(source).parse
      end

      # @param source [String]
      def initialize(source)
        @source = source
        @result = Result.new(definitions: [], enhancements: [], method_definitions: [], constants: [])
        @pending_description = nil
      end

      # @return [Result]
      def parse
        program = Prism.parse(@source).value
        visit_all(program)
        @result.facts = RakeBodyFacts.collect(program)
        @result
      end

      private

      # Pre-order, in source order, on an explicit stack: nested namespaces,
      # call chains and arguments nest as deep as they are long.
      def visit_all(program)
        stack = [[program, Context.new([], [], [])]]
        stack.concat(visit(*stack.pop).reverse) until stack.empty?
      end

      # @return [Array<Array(Prism::Node, Context)>] the children still to visit
      def visit(node, context)
        case node
        when nil then []
        when Prism::CallNode then visit_call(node, context)
        when Prism::IfNode then visit_conditional(node, node.subsequent, false, context)
        when Prism::UnlessNode then visit_conditional(node, node.else_clause, true, context)
        when Prism::DefNode then visit_method(node, context)
        when Prism::ModuleNode, Prism::ClassNode then visit_constant(node, context)
        else visit_children(node, context)
        end
      end

      def visit_children(node, context)
        node.compact_child_nodes.map { |child| [child, context] }
      end

      def visit_call(node, context)
        return visit_dsl_call(node, context) if node.receiver.nil?
        return record_task_class(node, context) if node.name == :new && task_class?(node.receiver)
        return [] if node.name == :enhance && record_enhancement(node, context)

        visit_children(node, context)
      end

      def visit_dsl_call(node, context)
        if node.name == :namespace && node.block.is_a?(Prism::BlockNode)
          visit_namespace(node, context)
        elsif node.name == :desc
          @pending_description = description_of(node)
          []
        elsif DEFINERS.key?(node.name)
          record_definition(node, DEFINERS.fetch(node.name), context)
        else
          visit_children(node, context)
        end
      end

      def visit_namespace(node, context)
        segment = RakeBodyFacts.literal_text(node.arguments&.arguments&.first)
        [[node.block.body, Context.new(context.namespace + [segment], context.conditions, context.modules)]]
      end

      def visit_conditional(node, alternative, negated, context)
        predicate = node.predicate.slice[0, CONDITION_LIMIT]
        holds, fails = negated ? ["!(#{predicate})", predicate] : [predicate, "!(#{predicate})"]
        [[node.statements, with_condition(context, holds)], [alternative, with_condition(context, fails)]]
      end

      def with_condition(context, condition)
        Context.new(context.namespace, context.conditions + [condition], context.modules)
      end

      def visit_method(node, context)
        @result.method_definitions << { name: node.name.to_s, line: node.location.start_line,
                                        facts: RakeBodyFacts.collect(node.body) }
        [[node.body, context]]
      end

      def visit_constant(node, context)
        modules = context.modules + [node.constant_path.slice.delete_prefix('::')]
        @result.constants << modules.join('::')
        [[node.body, Context.new(context.namespace, context.conditions, modules)]]
      end

      def description_of(node)
        text = RakeBodyFacts.literal_text(node.arguments&.arguments&.first)
        { text: text, literal: !text.nil? }
      end

      def take_description
        description = @pending_description
        @pending_description = nil
        description || { text: nil, literal: true }
      end

      def record_definition(node, kind, context)
        name_node, argument_nodes, prerequisite_node = signature(node.arguments&.arguments.to_a)
        name = kind == :rule ? rule_name(name_node) : RakeBodyFacts.literal_text(name_node)
        @result.definitions << build_definition(
          node, context, kind: kind, name: name, task_class: nil,
                         arguments: literal_list(argument_nodes).first, prerequisite_node: prerequisite_node
        )
        []
      end

      def record_task_class(node, context)
        task_class = node.receiver.slice.delete_prefix('::')
        name_node, argument_nodes, prerequisite_node = signature(node.arguments&.arguments.to_a)
        name = RakeBodyFacts.literal_text(name_node)
        name ||= TASK_CLASS_DEFAULTS[task_class] if name_node.nil?
        @result.definitions << build_definition(
          node, context, kind: :task_class, name: name, task_class: task_class,
                         arguments: literal_list(argument_nodes).first, prerequisite_node: prerequisite_node
        )
        []
      end

      def build_definition(node, context, kind:, name:, task_class:, arguments:, prerequisite_node:)
        description = take_description
        prerequisites, prerequisites_literal = literal_list(Array(prerequisite_node))
        {
          kind: kind, name: name, namespace: context.namespace, full_name: full_name(kind, name, context.namespace),
          description: description[:text], description_literal: description[:literal],
          prerequisites: prerequisites, prerequisites_literal: prerequisites_literal, arguments: arguments,
          task_class: task_class, conditions: context.conditions
        }.merge(site(node))
      end

      def record_enhancement(node, context)
        target = RakeBodyFacts.lookup_target(node.receiver)
        return false unless target

        prerequisites, prerequisites_literal = literal_list(node.arguments&.arguments.to_a.first(1))
        @result.enhancements << {
          target: target, namespace: context.namespace, prerequisites: prerequisites,
          prerequisites_literal: prerequisites_literal, conditions: context.conditions
        }.merge(site(node))
        true
      end

      # Where a call sits and what its block does.
      def site(node)
        block = node.block if node.block.is_a?(Prism::BlockNode)
        {
          line: node.location.start_line, block_line: block&.location&.start_line,
          body: block ? body_source(block) : '', facts: RakeBodyFacts.collect(block)
        }
      end

      # Everything inside a block: from the end of its `do`/`{` and any
      # `|params|` to the start of its `end`/`}`. A statement that shares a
      # line with either delimiter is kept (LOS-129); a blank remainder of the
      # opening line and the indentation before the closing delimiter are
      # dropped, so a block of whole lines is those lines. A block that opens
      # and closes on one line yields its statements.
      def body_source(block)
        return block.body&.slice.to_s if block.location.start_line == block.location.end_line

        from = [block.opening_loc.end_offset, block.parameters&.location&.end_offset].compact.max
        inner = @source.byteslice(from...block.closing_loc.start_offset).to_s
        trim_delimiter_lines(inner)
      end

      BLANK = /\A[ \t]*\z/
      private_constant :BLANK

      # Drops a blank remainder of the opening line and the indentation
      # before the closing delimiter. Both are tested on the bounded text
      # around a newline, never by a pattern searching the whole body, whose
      # length is the host's.
      #
      # @param inner [String]
      # @return [String]
      def trim_delimiter_lines(inner)
        first = inner.index("\n")
        inner = inner[(first + 1)..] if first && BLANK.match?(inner[0...first])
        last = inner.rindex("\n")
        inner = inner[0..last] if last && BLANK.match?(inner[(last + 1)..])
        inner
      end

      # Mirrors `Rake::TaskManager#resolve_args`.
      #
      # @return [Array(Prism::Node, Array<Prism::Node>, Prism::Node)] name, argument names, prerequisites
      def signature(arguments)
        key, value = name_association(arguments.last)
        return [arguments.first, arguments.drop(1), nil] unless key

        positional = arguments[0...-1]
        positional.empty? ? [key, [], value] : [positional.first, positional.drop(1) + [key], value]
      end

      def name_association(node)
        return nil unless node.is_a?(Prism::HashNode) || node.is_a?(Prism::KeywordHashNode)

        association = node.elements.find do |element|
          element.is_a?(Prism::AssocNode) && !OPTION_KEYS.include?(RakeBodyFacts.literal_text(element.key))
        end
        [association.key, association.value] if association
      end

      # @return [Array(Array<String>, Boolean)] literal names, and whether every element was literal
      def literal_list(nodes)
        elements = nodes.flat_map { |node| node.is_a?(Prism::ArrayNode) ? node.elements : [node] }
        names = elements.map { |element| RakeBodyFacts.literal_text(element) }
        [names.compact, names.none?(&:nil?)]
      end

      def rule_name(node)
        RakeBodyFacts.literal_text(node) || node&.slice
      end

      def full_name(kind, name, namespace)
        return name if name.nil? || UNSCOPED_KINDS.include?(kind)
        return nil if namespace.any?(&:nil?)

        (namespace + [name]).join(':')
      end

      def task_class?(node)
        return false unless node.is_a?(Prism::ConstantReadNode) || node.is_a?(Prism::ConstantPathNode)

        node.slice.end_with?(TASK_CLASS_SUFFIX) && node.slice.delete_prefix('::') != 'Rake::Task'
      end
    end
  end
end
