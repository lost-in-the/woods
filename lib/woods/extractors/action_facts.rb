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
      IVAR_WRITES = [Prism::InstanceVariableWriteNode, Prism::InstanceVariableOrWriteNode,
                     Prism::InstanceVariableAndWriteNode, Prism::InstanceVariableOperatorWriteNode,
                     Prism::InstanceVariableTargetNode].freeze

      # The instance-method definition Ruby dispatches: the +def+ at +line+,
      # or the only +def+ by that name when the line does not match.
      #
      # @param program [Prism::ProgramNode] a parsed file
      # @param name [String] method name
      # @param line [Integer, nil] the line +source_location+ reports
      # @return [Prism::DefNode, nil]
      def self.definition(program, name, line)
        defs = []
        stack = [program]
        until stack.empty?
          node = stack.pop
          defs << node if node.is_a?(Prism::DefNode) && node.receiver.nil? && node.name.to_s == name.to_s
          stack.concat(node.compact_child_nodes)
        end
        defs.find { |d| d.location.start_line == line } || (defs.first if defs.size == 1)
      end

      # @param node [Prism::DefNode, nil]
      # @param view_prefix [String] the controller or mailer view path, e.g. +users+
      # @param permitted [Hash{String => String}] permitted-params method => model key
      # @param mailer [Boolean] read +mail+ as the render and add no implicit render without it
      # @param implicit [Boolean] add the implicit render when the body has no response (false for a filter)
      # @return [Hash] +assigns+, +params+, +renders+, +redirects+, +formats+
      def self.scan(node, view_prefix:, permitted: {}, mailer: false, implicit: true)
        scanner = new(node&.name.to_s, view_prefix, permitted.to_h, mailer: mailer, implicit: implicit)
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
        if node.name == :respond_to && node.receiver.nil? && node.block.is_a?(Prism::BlockNode)
          with_format_variable(node.block) { super }
        else
          super
        end
      end

      private

      def assign(node)
        @assigns << { ivar: node.name.to_s, line: node.location.start_line }
      end

      def record_call(node)
        if node.receiver.nil?
          receiverless(node)
        elsif params_receiver?(node.receiver) && PARAMS_READERS.include?(node.name)
          param(node)
        elsif format_call?(node)
          @formats << node.name.to_s unless @formats.include?(node.name.to_s)
        end
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
        receiver.is_a?(Prism::CallNode) && receiver.name == :params && receiver.receiver.nil? && receiver.arguments.nil?
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

        first_key(hash.elements.first&.key)
      end

      def render(node)
        @responded = true
        args = node.arguments&.arguments || []
        options = keyword_options(args.last)
        fact = render_target(args.first, options)
        fact[:line] = line(node)
        fact[:status] = literal(options[:status]) if options[:status]
        @renders << fact
      end

      def render_target(first, options)
        if (format = BODY_FORMATS.find { |key| options.key?(key) })
          { format: format.to_s }
        elsif options[:partial]
          partial = { partial: partial_path(literal(options[:partial])) }
          partial[:locals] = hash_keys(options[:locals]) if options[:locals]
          partial
        elsif options[:template] || options[:action]
          { template: template_path(literal(options[:template] || options[:action])) }
        elsif (name = literal(first))
          { template: template_path(name) }
        else
          { object: first&.slice.to_s }
        end
      end

      def head(node)
        @responded = true
        @renders << { head: literal(node.arguments&.arguments&.first).to_s, line: line(node) }
      end

      def mail(node)
        options = keyword_options(node.arguments&.arguments&.last)
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
