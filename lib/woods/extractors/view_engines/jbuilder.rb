# frozen_string_literal: true

require 'set'
require_relative 'erb'

module Woods
  module Extractors
    module ViewEngines
      # Jbuilder implementation of the {Base} template-engine contract.
      #
      # A jbuilder template is plain Ruby, so partials come from
      # `json.partial!` and from the `partial:` option any `json.*` call
      # accepts (`json.array! @widgets, partial: '...'`). A partial whose
      # path is built at runtime (`json.partial! some_path_helper(...)`) or
      # derived from an object (`json.partial! @order.customer`) is reported
      # through {#scan_unresolved_partials} and never becomes an edge.
      #
      # Inherits the helper vocabulary, instance-variable scan, and
      # route-helper candidates from {Erb}.
      class Jbuilder < Erb
        # File extensions this engine handles.
        EXTENSIONS = %w[.json.jbuilder .jbuilder].freeze

        # Stable engine identifier — see Base#name.
        ENGINE_NAME = :jbuilder

        # Every quantifier that could meet another one over the same
        # characters is possessive, so scans stay linear on uncontrolled
        # template text.

        # `json.partial! 'path'` and `json.partial!('path', ...)`.
        POSITIONAL_PARTIAL = /\bjson\.partial!\s*+(?:\(\s*+)?['"]([^'"]+)['"]/

        # The start of a `json.*` call within a statement.
        JSON_CALL = /\bjson\.\w/

        # A literal `partial:` (or `:partial =>`) option, read from the
        # arguments that follow a `json.*` call.
        PARTIAL_OPTION = /(?:\bpartial:|:partial\s*+=>)\s*+['"]([^'"]+)['"]/

        # A Ruby expression where a partial path is expected: a method call
        # or an object reference such as `@order.customer`. The expression
        # is read whole, and the lookahead rejects a keyword like `partial:`.
        RUNTIME_EXPRESSION = '(@?[a-z_]\w*+(?:\.\w++)*+)(?![\w:])(\()?'

        # `json.partial! <expression>` as the first argument.
        POSITIONAL_RUNTIME_PARTIAL = /\bjson\.partial!\s*+(?:\(\s*+)?#{RUNTIME_EXPRESSION}/

        # `partial: <expression>`, read from the arguments that follow a
        # `json.*` call.
        RUNTIME_PARTIAL_OPTION = /\bpartial:\s*+#{RUNTIME_EXPRESSION}/

        # @see Base#name
        def name
          ENGINE_NAME
        end

        # @see Base#extensions
        def extensions
          EXTENSIONS
        end

        # @see Base#scan_partials
        def scan_partials(source)
          partials = Set.new
          source.scan(POSITIONAL_PARTIAL) { |(name)| partials << name }
          json_call_arguments(source).each do |arguments|
            arguments.scan(PARTIAL_OPTION) { |(name)| partials << name }
          end
          partials.to_a
        end

        # A runtime expression followed by `(` is a helper call; anything
        # else is treated as an object. A paren-less helper call with
        # arguments is therefore recorded as an object; the name is kept.
        #
        # @see Base#scan_unresolved_partials
        def scan_unresolved_partials(source)
          matches = source.scan(POSITIONAL_RUNTIME_PARTIAL) +
                    json_call_arguments(source).flat_map { |arguments| arguments.scan(RUNTIME_PARTIAL_OPTION) }
          matches.map { |expression, call_paren| { kind: call_paren ? 'helper' : 'object', name: expression } }.uniq
        end

        # Route helpers only: a JSON template has no forms.
        #
        # @see Base#scan_navigation_candidates
        def scan_navigation_candidates(source)
          source.scan(ROUTE_HELPER_PATTERN).map do |route_name, suffix|
            { helper: "#{route_name}_#{suffix}", via: :link_to }
          end
        end

        private

        # @see Erb#partial_extension
        def partial_extension
          '.json.jbuilder'
        end

        # Each statement's text from its first `json.*` call onward.
        #
        # @param source [String]
        # @return [Array<String>]
        def json_call_arguments(source)
          statements(source).filter_map do |statement|
            start = statement =~ JSON_CALL
            statement[start..] if start
          end
        end
      end
    end
  end
end
