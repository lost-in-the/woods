# frozen_string_literal: true

require 'prism'
require 'set'
require_relative '../source_file'
require_relative 'callback_analyzer'

module Woods
  module Extractors
    # Structured state machine transition callbacks (#796).
    #
    # Reads `before_transition`, `after_transition`, `around_transition` and
    # `after_failure` calls with Prism, so a comment or a string that
    # mentions one is not a callback, and publishes each as
    #
    #   { kind:, on:, from:, to:, method:, block:, side_effects: }
    #
    # The scope (`on`, `from`, `to`) is the literal one: symbols and arrays
    # of symbols, from keywords or a `from => to` pair. `any` is no
    # restriction and stays empty; any other expression is never evaluated:
    # the field stays empty and is named in `unresolved`.
    #
    # A symbol method is analysed with {CallbackAnalyzer}, the same analysis
    # model callbacks get, over the model file and the app/models concerns
    # it includes by a literal `include`. A block or proc is marked and left
    # unanalysed, as is a method neither defines (`unanalysed` says which).
    module TransitionCallbacks
      KINDS = %w[before_transition after_transition around_transition after_failure].freeze

      # Keys that name a scope rather than an option.
      SCOPE_KEYS = %w[on from to].freeze

      # Option keys of the three gems; any other key is a `from => to` pair.
      OPTION_KEYS = %w[do if unless except_from except_to except_on after_commit].freeze

      # Where an included concern is looked up, relative to the root. Both
      # sit under app/models, whose changes re-run the state machine family.
      CONCERN_DIRECTORIES = %w[app/models/concerns app/models].freeze

      UNDEFINED = 'not defined in the model or its concerns'

      module_function

      # @param node [Prism::Node, nil] the machine's block, or the whole program
      # @return [Array<Hash>] entries in source order, side effects not yet set
      def read(node)
        calls = []
        collect(node, calls)
        calls.sort_by { |call| call.location.start_offset }.flat_map { |call| entries(call) }
      end

      # @param entries [Array<Hash>] from {.read}
      # @param analyzer [CallbackAnalyzer]
      # @return [Array<Hash>] entries with side_effects (nil when unanalysed)
      def analyze(entries, analyzer)
        defined = method_names(analyzer)
        entries.map do |entry|
          if entry[:block]
            entry.merge(side_effects: nil, unanalysed: 'block')
          elsif defined.include?(entry[:method])
            entry.merge(side_effects: analyzer.analyze(filter: entry[:method])[:side_effects])
          else
            entry.merge(side_effects: nil, unanalysed: UNDEFINED)
          end
        end
      end

      # The model file followed by the concerns it includes by name, with the
      # segment each occupies, for {CallbackAnalyzer}.
      #
      # @param source [String] the model file
      # @param file_path [String] its absolute path
      # @param root [String] the application root
      # @return [Array(String, Array<Hash>)]
      def analysis_source(source, file_path, root)
        parts = [[source, relative(file_path, root)]] + included_concerns(source, root)
        start = 1
        segments = parts.map do |code, path|
          length = code.count("\n") + (code.end_with?("\n") ? 0 : 1)
          segment = { start: start, length: length, file: path }
          start += length + (code.end_with?("\n") ? 2 : 1)
          segment
        end
        [parts.map(&:first).join("\n\n"), segments]
      end

      # ── reading ──────────────────────────────────────────────────────────

      # Callback calls under +node+, not inside a method body: a callback
      # is class-level DSL.
      def collect(node, calls)
        return unless node
        return if node.is_a?(Prism::DefNode)

        if node.is_a?(Prism::CallNode) && KINDS.include?(node.name.to_s) &&
           (node.receiver.nil? || node.receiver.is_a?(Prism::SelfNode))
          calls << node
        end
        node.compact_child_nodes.each { |child| collect(child, calls) }
      end

      def entries(call)
        arguments = Array(call.arguments&.arguments)
        hash = arguments.find { |node| node.is_a?(Prism::KeywordHashNode) || node.is_a?(Prism::HashNode) }
        scope = { on: [], from: [], to: [] }
        unresolved = []
        methods = arguments.grep(Prism::SymbolNode).map(&:unescaped)
        block = !call.block.nil? && !call.block.is_a?(Prism::BlockArgumentNode)

        Array(hash&.elements).each do |assoc|
          next unless assoc.is_a?(Prism::AssocNode)

          key = assoc.key.is_a?(Prism::SymbolNode) ? assoc.key.unescaped : nil
          if key == 'do'
            names = literal(assoc.value)
            names ? methods.concat(names) : block = true
          elsif SCOPE_KEYS.include?(key)
            assign(scope, unresolved, key.to_sym, assoc.value)
          elsif !OPTION_KEYS.include?(key)
            assign(scope, unresolved, :from, assoc.key)
            assign(scope, unresolved, :to, assoc.value)
          end
        end

        base = { kind: call.name.to_s }.merge(scope)
        base[:unresolved] = unresolved.uniq unless unresolved.empty?
        return [base.merge(method: nil, block: true)] if methods.empty?

        methods.map { |name| base.merge(method: name, block: block) }
      end

      def assign(scope, unresolved, field, node)
        return if any?(node)

        values = literal(node)
        values ? scope[field].concat(values) : unresolved << field.to_s
      end

      # `any` with no receiver or arguments: every state.
      def any?(node)
        node.is_a?(Prism::CallNode) && node.name == :any && node.receiver.nil? && node.arguments.nil?
      end

      # @return [Array<String>, nil] the symbols, nil when not all literal
      def literal(node)
        case node
        when Prism::SymbolNode then [node.unescaped]
        when Prism::ArrayNode
          values = node.elements.map { |element| element.is_a?(Prism::SymbolNode) ? element.unescaped : nil }
          values.all? ? values : nil
        end
      end

      # ── analysis ─────────────────────────────────────────────────────────

      def method_names(analyzer)
        root = analyzer.parsed_root
        root ? root.find_all(:def).to_set(&:method_name) : Set.new
      end

      def included_concerns(source, root)
        names = include_names(source)
        names.filter_map do |name|
          path = CONCERN_DIRECTORIES.map { |dir| File.join(root, dir, "#{name.underscore}.rb") }.find { |p| File.file?(p) }
          [SourceFile.read(path), relative(path, root)] if path
        end
      end

      # Constants passed to a receiverless `include` anywhere in a class body.
      def include_names(source)
        names = []
        visit = lambda do |node|
          next unless node
          next if node.is_a?(Prism::DefNode)

          if node.is_a?(Prism::CallNode) && node.name == :include && node.receiver.nil?
            Array(node.arguments&.arguments).each do |argument|
              if argument.is_a?(Prism::ConstantReadNode) || argument.is_a?(Prism::ConstantPathNode)
                names << argument.slice.delete_prefix('::')
              end
            end
          end
          node.compact_child_nodes.each { |child| visit.call(child) }
        end
        visit.call(Prism.parse(source).value)
        names.uniq
      end

      def relative(path, root)
        prefix = File.join(root, '')
        path.to_s.start_with?(prefix) ? path.to_s.delete_prefix(prefix) : nil
      end
    end
  end
end
