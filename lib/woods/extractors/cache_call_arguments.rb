# frozen_string_literal: true

require 'prism'

module Woods
  module Extractors
    # Reads the arguments of one cache call from its source text: the key
    # expression, the `expires_in` expression, and the literal-valued cache
    # options.
    #
    # The call may sit in a Ruby file, an ERB tag, a HAML line, or a jbuilder
    # template, so only the call itself is parsed: the text from the call's
    # start to the end of its ERB tag or line, widened a line at a time
    # while the arguments are still open. A trailing `do` gets a synthetic
    # `end` so the block parses.
    module CacheCallArguments
      module_function

      # Options recorded when their value is a literal.
      OPTION_KEYS = %i[expires_in race_condition_ttl if unless].freeze

      # Calls whose first positional argument is a condition, not the key.
      CONDITIONAL_CALLS = %i[cache_if cache_unless cache_if! cache_unless!].freeze

      # Names of the calls this module reads. The call at an occurrence may
      # sit inside a larger expression (`Rails.cache.read(k).present?`,
      # `Rails.cache.read(k) || fallback`), so it is found by name among the
      # nodes that start where the occurrence starts.
      CALL_NAMES = (%i[fetch read write delete exist? cache cache! caches_action] + CONDITIONAL_CALLS).freeze

      # `1.hour`-style duration calls count as literals.
      DURATION_METHODS = %i[
        second seconds minute minutes hour hours day days week weeks fortnight fortnights month months year years
      ].freeze

      LITERAL_NODES = [
        Prism::IntegerNode, Prism::FloatNode, Prism::SymbolNode, Prism::StringNode,
        Prism::TrueNode, Prism::FalseNode, Prism::NilNode
      ].freeze

      KEY_LIMIT = 120
      MAX_LINES = 8
      MAX_BYTES = 2_000

      # @param source [String] File source
      # @param offset [Integer] Byte offset where the cache call begins
      # @return [Hash] `:key_pattern` (String, nil), `:ttl` (String, nil),
      #   `:options` (Hash{Symbol => String}), and `:argument_range`
      #   (Range, nil): the byte range of the call's arguments in `source`
      def read(source, offset)
        call = parse_call(source, offset)
        return { key_pattern: nil, ttl: nil, options: {}, argument_range: nil } unless call

        options = keyword_options(call)
        {
          argument_range: argument_range(call, offset),
          key_pattern: key_expression(call)&.slice&.[](0, KEY_LIMIT),
          ttl: options[:expires_in]&.slice,
          options: OPTION_KEYS.each_with_object({}) do |name, literal|
            literal[name] = options[name].slice if options[name] && literal?(options[name])
          end
        }
      end

      # The first snippet that parses cleanly wins. When none does (a call
      # followed by `; end` on a one-line method), Prism's error recovery
      # on the one-line snippet still yields the call.
      def parse_call(source, offset)
        candidates = snippets(source, offset)
        candidates.each do |snippet|
          [snippet, "#{snippet}\nend"].each do |code|
            parsed = Prism.parse(code)
            return call_at_start(parsed) if parsed.success?
          end
        end
        candidates.first && call_at_start(Prism.parse(candidates.first))
      end

      # The outermost call named in {CALL_NAMES} among the nodes that begin
      # at the snippet start. Only nodes starting at offset 0 are followed,
      # so the walk is bounded by the snippet and never recurses.
      def call_at_start(parsed)
        pending = [parsed.value.statements.body.first].compact
        until pending.empty?
          node = pending.shift
          next unless node.location.start_offset.zero?
          return node if node.is_a?(Prism::CallNode) && CALL_NAMES.include?(node.name)

          pending.concat(node.compact_child_nodes)
        end
        nil
      end

      # Candidate call texts, shortest first, cut at the end of an ERB tag.
      # The window is taken in bytes so `offset` maps straight onto Prism's
      # byte locations; `scrub` repairs a character cut at the window end.
      def snippets(source, offset)
        text = source.byteslice(offset, MAX_BYTES).scrub
        tag_end = text.index(/-?%>/)
        text = text[0...tag_end] if tag_end
        lines = text.lines
        (1..[lines.size, MAX_LINES].min).map { |count| lines.first(count).join.chomp }
      end

      def argument_range(call, offset)
        location = call.arguments&.location
        location && ((offset + location.start_offset)...(offset + location.end_offset))
      end

      def positional_arguments(call)
        (call.arguments&.arguments || []).reject do |node|
          node.is_a?(Prism::KeywordHashNode) || node.is_a?(Prism::BlockArgumentNode)
        end
      end

      def key_expression(call)
        positional_arguments(call)[CONDITIONAL_CALLS.include?(call.name) ? 1 : 0]
      end

      def keyword_options(call)
        hash = (call.arguments&.arguments || []).find { |node| node.is_a?(Prism::KeywordHashNode) }
        return {} unless hash

        hash.elements.each_with_object({}) do |element, options|
          next unless element.is_a?(Prism::AssocNode) && element.key.is_a?(Prism::SymbolNode)

          options[element.key.unescaped.to_sym] = element.value
        end
      end

      def literal?(node)
        return true if LITERAL_NODES.any? { |klass| node.is_a?(klass) }

        node.is_a?(Prism::CallNode) && DURATION_METHODS.include?(node.name) && node.arguments.nil? &&
          (node.receiver.is_a?(Prism::IntegerNode) || node.receiver.is_a?(Prism::FloatNode))
      end
      private_class_method :parse_call, :call_at_start, :snippets, :argument_range, :positional_arguments, :key_expression,
                           :keyword_options, :literal?
    end
  end
end
