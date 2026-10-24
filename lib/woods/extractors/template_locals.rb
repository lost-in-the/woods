# frozen_string_literal: true

require 'prism'

module Woods
  module Extractors
    # Partial locals in one template's Ruby (woods#798), read from its syntax
    # tree: the locals each literal partial render passes, and the bare
    # identifiers the template reads. The input keeps the template's line
    # numbers (see {ViewEngines::Erb#ruby_lines}), so each render carries the
    # line it sits on.
    #
    # Reads are lexical and deliberately wide: a bare identifier may be a
    # local or a helper method, and both are listed. A consumer comparing
    # passed locals against reads can therefore trust a passed local that is
    # missing from the reads, never the reverse. A template that reaches
    # locals in a way no name can be read from (`local_assigns` iterated or
    # indexed by a variable, `binding`) is marked dynamic.
    #
    # @example
    #   TemplateLocals.scan(%(render "posts/card", post: @post;\npost.title;))
    #   # => { renders: [{ partial: "posts/card", locals: ["post"], implicit_local: nil,
    #   #                  dynamic_locals: false, line: 1 }],
    #   #      reads: ["post"], dynamic: false }
    class TemplateLocals < Prism::Visitor
      # Calls on `local_assigns` that name the local they read.
      LOCAL_ASSIGNS_READERS = %i[[] fetch key? has_key? include? member? dig].freeze

      # @param code [String] the template's Ruby with its line numbers kept
      # @return [Hash] +renders+ (Array<Hash>), +reads+ (sorted Array<String>), +dynamic+ (Boolean)
      def self.scan(code)
        scanner = new
        Prism.parse(code).value.accept(scanner)
        scanner.result
      end

      # Strict locals a magic comment declares: `locals: (title:, size: 1, **rest)`.
      #
      # @param parameters [String] the text between the comment's parentheses
      # @return [Hash, nil] +required+ and +optional+ names and whether +any+ other local is accepted;
      #   nil when the list does not parse
      def self.declared(parameters)
        result = Prism.parse("def __woods_locals(#{parameters}); end")
        return nil if result.errors.any?

        params = result.value.statements.body.first.parameters
        keywords = Array(params&.keywords)
        { required: keywords.grep(Prism::RequiredKeywordParameterNode).map { |node| node.name.to_s },
          optional: keywords.grep(Prism::OptionalKeywordParameterNode).map { |node| node.name.to_s },
          any: params&.keyword_rest.is_a?(Prism::KeywordRestParameterNode) || false }
      end

      def initialize
        super
        @renders = []
        @reads = []
        @dynamic = false
        @claimed = {}.compare_by_identity
      end

      # @return [Hash]
      def result
        { renders: @renders, reads: @reads.uniq.sort, dynamic: @dynamic }
      end

      # @param node [Prism::CallNode]
      def visit_call_node(node)
        if node.receiver.nil?
          receiverless(node)
        elsif local_assigns?(node.receiver)
          local_assigns_reader(node)
        end
        super
      end

      # @param node [Prism::LocalVariableReadNode]
      def visit_local_variable_read_node(node)
        @reads << node.name.to_s
        super
      end

      private

      def receiverless(node)
        if node.name == :binding
          @dynamic = true
        elsif node.variable_call?
          name = node.name.to_s
          @dynamic = true if name == 'local_assigns' && !@claimed[node]
          @reads << name unless name == 'local_assigns'
        elsif node.name == :render
          render(node)
        end
      end

      def local_assigns?(node)
        node.is_a?(Prism::CallNode) && node.receiver.nil? && node.variable_call? && node.name == :local_assigns
      end

      def local_assigns_reader(node)
        key = literal(node.arguments&.arguments&.first)
        return unless LOCAL_ASSIGNS_READERS.include?(node.name) && key

        @claimed[node.receiver] = true
        @reads << key
      end

      def render(node)
        args = node.arguments&.arguments || []
        fact = if (name = literal(args.first))
                 by_name(name, args[1])
               elsif hash?(args.first)
                 by_options(args.first)
               end
        @renders << fact.merge(line: node.location.start_line) if fact
      end

      # `render "posts/card", post: @post`: every key of the second argument is a local.
      def by_name(name, locals)
        keys = locals.nil? ? [] : hash_keys(locals)
        { partial: name, locals: Array(keys), implicit_local: nil, dynamic_locals: !locals.nil? && keys.nil? }
      end

      # `render partial: "posts/card", locals: {...}, collection: @posts, as: :post`.
      def by_options(hash)
        options = hash.elements.grep(Prism::AssocNode).to_h { |assoc| [literal(assoc.key), assoc.value] }
        name = literal(options['partial'])
        return nil unless name

        keys = options.key?('locals') ? hash_keys(options['locals']) : []
        { partial: name, locals: Array(keys), implicit_local: implicit_local(name, options),
          dynamic_locals: keys.nil? || hash.elements.any?(Prism::AssocSplatNode) }
      end

      # Rails names the object or collection member after `as:`, else after the partial.
      def implicit_local(name, options)
        return nil unless options.key?('object') || options.key?('collection')

        literal(options['as']) || File.basename(name).delete_prefix('_')
      end

      # @return [Array<String>, nil] the literal keys, nil when any key is not literal
      def hash_keys(node)
        return nil unless hash?(node)

        keys = node.elements.map { |element| element.is_a?(Prism::AssocNode) ? literal(element.key) : nil }
        keys.all? ? keys : nil
      end

      def hash?(node)
        node.is_a?(Prism::KeywordHashNode) || node.is_a?(Prism::HashNode)
      end

      def literal(node)
        node.unescaped if node.is_a?(Prism::StringNode) || node.is_a?(Prism::SymbolNode)
      end
    end
  end
end
