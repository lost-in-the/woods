# frozen_string_literal: true

require 'prism'

module Woods
  module Extractors
    # What one action, filter or mailer action body says, read from its
    # syntax tree (W-7, woods#757): the instance variables it assigns, the
    # params it reads, what it renders, where it redirects and the formats a
    # +respond_to+ block names.
    #
    # A syntax-tree walk, so a comment, a string or a heredoc never supplies
    # a fact. Every fact carries the line it sits on, relative to the file the
    # definition was parsed from. Nothing here resolves a call: a helper the
    # body calls may assign more, which the facts do not claim to cover.
    #
    # @example
    #   program = Prism.parse(source).value
    #   node = ActionFacts.definition(program, 'show', 11)
    #   ActionFacts.scan(node, view_prefix: 'users')
    #   # => { assigns: [{ ivar: '@user', line: 12 }], params: [...], renders: [...], ... }
    class ActionFacts < Prism::Visitor
      # Calls that read a key from params, the key being the first argument.
      PARAMS_READERS = %i[[] fetch require expect dig key? has_key? include?].freeze
      # `render` keywords that name a response body instead of a template.
      BODY_FORMATS = %i[json xml plain html body js inline].freeze
      REDIRECTS = %i[redirect_to redirect_back redirect_back_or_to].freeze
      RECEIVER_CHANGING_METHODS = %i[instance_eval instance_exec class_eval class_exec module_eval module_exec].freeze
      GENERATED_DEFINITIONS = %i[attr attr_reader attr_writer attr_accessor define_method].freeze
      IVAR_WRITES = [Prism::InstanceVariableWriteNode, Prism::InstanceVariableOrWriteNode,
                     Prism::InstanceVariableAndWriteNode, Prism::InstanceVariableOperatorWriteNode,
                     Prism::InstanceVariableTargetNode].freeze

      # Index instance-method definitions once per source file. Ambiguous
      # same-name, same-line definitions remain separate candidates.
      #
      # @param program [Prism::ProgramNode] a parsed file
      # Nil-name entries mark ambiguous source lines. Blocks, generated
      # declarations and multiple defs can supply a renamed Proc-backed
      # method's source site, even when another file installs that method.
      # @return [Hash{Array(String, nil, Integer) => Array<Prism::DefNode, nil>}]
      def self.definitions(program)
        definitions = Hash.new { |hash, key| hash[key] = [] }
        definition_counts = Hash.new(0)
        stack = [program]
        until stack.empty?
          node = stack.pop
          if node.is_a?(Prism::DefNode)
            line = node.location.start_line
            definition_counts[line] += 1
            definitions[[node.name.to_s, line]] << node if node.receiver.nil?
          elsif node.is_a?(Prism::BlockNode) || node.is_a?(Prism::LambdaNode)
            definitions[[nil, node.opening_loc.start_line]] << nil
          elsif node.is_a?(Prism::CallNode) && generated_definition?(node)
            # Ruby attributes generated methods to the called method token,
            # which can follow a receiver on a different line.
            [node.location.start_line, node.message_loc&.start_line].compact.uniq.each do |line|
              definitions[[nil, line]] << nil
            end
          end
          stack.concat(node.compact_child_nodes)
        end
        definition_counts.each { |line, count| definitions[[nil, line]] << nil if count > 1 }
        definitions
      end

      def self.generated_definition?(node)
        return true if GENERATED_DEFINITIONS.include?(node.name)
        return false unless %i[send public_send __send__].include?(node.name)

        target = node.arguments&.arguments&.first
        while target.is_a?(Prism::ParenthesesNode)
          expressions = target.body&.body
          return false unless expressions&.one?

          target = expressions.first
        end
        return false unless target.is_a?(Prism::SymbolNode) || target.is_a?(Prism::StringNode)

        GENERATED_DEFINITIONS.any? { |name| name.to_s == target.unescaped }
      end
      private_class_method :generated_definition?

      # A runtime source site must match exactly. Source-only callers without
      # a line can select a name only when it identifies one definition.
      #
      # @param program [Prism::ProgramNode, Hash] a parsed file or definition index
      # @param name [String] the runtime method's original name
      # @param line [Integer, nil] the line +source_location+ reports
      # @return [Prism::DefNode, nil]
      def self.definition(program, name, line)
        definitions = program.is_a?(Hash) ? program : self.definitions(program)
        return if line && definitions.key?([nil, line])

        matches = definitions.fetch([name.to_s, line], [])
        return matches.first if matches.size == 1
        return if line || matches.any?

        candidates = definitions.select { |(defined_name, _), _| defined_name == name.to_s }
        return if candidates.any? { |(_, defined_line), _| definitions.key?([nil, defined_line]) }

        nodes = candidates.values.flatten
        nodes.first if nodes.size == 1
      end

      # @param node [Prism::DefNode, nil]
      # @param view_prefix [String] the controller or mailer view path, e.g. +users+
      # @param permitted [Hash{String => String}] permitted-params method => model key
      # @param mailer [Boolean] read +mail+ as the render and add no implicit render without it
      # @param implicit [Boolean] add the implicit render when the body has no response (false for a filter)
      # @param action [String] dispatched action name, which can differ from an aliased definition's name
      # @return [Hash] +assigns+, +params+, +renders+, +redirects+, +formats+
      def self.scan(node, view_prefix:, permitted: {}, mailer: false, implicit: true, action: node&.name.to_s)
        scanner = new(action, view_prefix, permitted.to_h, mailer: mailer, implicit: implicit)
        node&.body&.accept(scanner)
        scanner.result
      end

      def initialize(action, view_prefix, permitted, mailer: false, implicit: true)
        super()
        @implicit = implicit
        @action = action
        @view_prefix = view_prefix
        @permitted = permitted
        @mailer = mailer
        @assigns = []
        @params = []
        @renders = []
        @redirects = []
        @formats = []
        @format_variables = []
        @responded = false
      end

      # @return [Hash] the facts, with the implicit render when the body has no response
      def result
        renders = @renders.dup
        renders << { template: "#{@view_prefix}/#{@action}", implicit: true } if @implicit && !@responded && !@mailer
        { assigns: @assigns, params: @params, renders: renders, redirects: @redirects, formats: @formats }
      end

      IVAR_WRITES.each do |klass|
        visitor = :"visit_#{klass.name.split('::').last.gsub(/(?<!^)([A-Z])/, '_\1').downcase}"
        define_method(visitor) do |node|
          assign(node)
          super(node)
        end
      end

      # @param node [Prism::CallNode]
      def visit_call_node(node)
        record_call(node)
        if foreign_body_call?(node)
          node.compact_child_nodes.each { |child| child.accept(self) unless child.equal?(node.block) }
        elsif node.name == :respond_to && own_receiver?(node.receiver) && node.block.is_a?(Prism::BlockNode)
          with_format_variable(node.block) { super }
        else
          super
        end
      end

      # A definition creates another callable; its body does not run as part
      # of the action. Class/module bodies also have a different self.
      def visit_def_node(_node); end

      def visit_class_node(_node); end

      def visit_module_node(_node); end

      def visit_singleton_class_node(node)
        node.expression.accept(self)
      end

      private

      def assign(node)
        @assigns << { ivar: node.name.to_s, line: node.location.start_line }
      end

      def record_call(node)
        if own_receiver?(node.receiver)
          receiverless(node)
        elsif params_receiver?(node.receiver) && PARAMS_READERS.include?(node.name)
          param(node)
        elsif format_call?(node)
          @formats << node.name.to_s unless @formats.include?(node.name.to_s)
        end
      end

      def own_receiver?(receiver)
        receiver.nil? || receiver.is_a?(Prism::SelfNode)
      end

      def foreign_body_call?(node)
        return false unless node.block.is_a?(Prism::BlockNode)
        return !own_receiver?(node.receiver) if RECEIVER_CHANGING_METHODS.include?(node.name)
        return false unless node.name == :new

        receiver = node.receiver
        constant = receiver.is_a?(Prism::ConstantReadNode) ||
                   (receiver.is_a?(Prism::ConstantPathNode) && receiver.parent.nil?)
        constant && %i[Class Module Struct].include?(receiver.name)
      end

      def receiverless(node)
        name = node.name
        if name == :render then render(node)
        elsif name == :head then head(node)
        elsif name == :mail && @mailer then mail(node)
        elsif REDIRECTS.include?(name) then redirect(node)
        elsif @permitted.key?(name.to_s) && node.arguments.nil?
          @params << { key: @permitted[name.to_s], line: line(node), permitted: true, via: name.to_s }
        end
      end

      def params_receiver?(receiver)
        receiver.is_a?(Prism::CallNode) && receiver.name == :params && own_receiver?(receiver.receiver) &&
          receiver.arguments.nil?
      end

      def param(node)
        key = first_key(node.arguments&.arguments&.first) || (expect_key(node) if node.name == :expect)
        return unless key

        entry = { key: key, line: line(node), permitted: false }
        @params << entry unless @params.include?(entry)
      end

      def expect_key(node)
        hash = node.arguments&.arguments&.first
        return unless hash.is_a?(Prism::KeywordHashNode) || hash.is_a?(Prism::HashNode)

        element = hash.elements.find { |entry| entry.is_a?(Prism::AssocNode) }
        first_key(element&.key)
      end

      def render(node)
        @responded = true
        args = node.arguments&.arguments || []
        options = keyword_options(args.last)
        fact = render_target(args.first, options)
        fact[:line] = line(node)
        fact[:status] = response_status(options[:status]) if options[:status]
        @renders << fact
      end

      def render_target(first, options)
        if (format = BODY_FORMATS.find { |key| options.key?(key) })
          { format: format.to_s }
        elsif options[:partial]
          name = literal(options[:partial])
          return { object: options[:partial].slice } unless name

          partial = { partial: partial_path(name) }
          partial[:locals] = hash_keys(options[:locals]) if options[:locals]
          partial
        elsif options[:template] || options[:action]
          target = options[:template] || options[:action]
          name = literal(target)
          name ? { template: template_path(name) } : { object: target.slice }
        elsif (name = literal(first))
          { template: template_path(name) }
        else
          { object: first&.slice.to_s }
        end
      end

      def head(node)
        @responded = true
        @renders << { head: response_status(node.arguments&.arguments&.first).to_s, line: line(node) }
      end

      def mail(node)
        options = keyword_options(node.arguments&.arguments&.last)
        if %i[template_name template_path].any? { |key| options[key] && !literal(options[key]) }
          @renders << { object: node.slice, line: line(node), mail: true }
          return
        end

        name = literal(options[:template_name]) || @action
        prefix = literal(options[:template_path]) || @view_prefix
        @renders << { template: "#{prefix}/#{name}", line: line(node), mail: true }
      end

      def redirect(node)
        @responded = true
        target = node.name == :redirect_to ? node.arguments&.arguments&.first&.slice.to_s : 'back'
        @redirects << { target: target, line: line(node) }
      end

      def with_format_variable(block)
        name = block.parameters&.parameters&.requireds&.first&.name
        @format_variables.push(name)
        yield
      ensure
        @format_variables.pop
      end

      def format_call?(node)
        node.receiver.is_a?(Prism::LocalVariableReadNode) && @format_variables.include?(node.receiver.name)
      end

      def keyword_options(node)
        return {} unless node.is_a?(Prism::KeywordHashNode) || node.is_a?(Prism::HashNode)

        node.elements.each_with_object({}) do |element, options|
          next unless element.is_a?(Prism::AssocNode)

          key = first_key(element.key)
          options[key.to_sym] = element.value if key
        end
      end

      def hash_keys(node)
        return [] unless node.is_a?(Prism::HashNode) || node.is_a?(Prism::KeywordHashNode)

        node.elements.filter_map { |element| first_key(element.key) if element.is_a?(Prism::AssocNode) }
      end

      def first_key(node)
        case node
        when Prism::SymbolNode, Prism::StringNode then node.unescaped
        end
      end

      def literal(node)
        first_key(node)
      end

      def response_status(node)
        node.is_a?(Prism::IntegerNode) ? node.value : literal(node)
      end

      def template_path(name)
        name.to_s.include?('/') ? name.to_s : "#{@view_prefix}/#{name}"
      end

      def partial_path(name)
        dir, base = name.to_s.include?('/') ? name.to_s.split(%r{/(?=[^/]+\z)}) : [@view_prefix, name.to_s]
        "#{dir}/_#{base}"
      end

      def line(node)
        node.location.start_line
      end
    end
  end
end
