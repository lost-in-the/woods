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

        # Arguments of one Ruby call: any character up to the end of the
        # line, crossing a line break only after a trailing comma.
        CALL_ARGUMENTS = '(?:[^\n]|,[ \t]*\n)*?'

        # `json.partial! 'path'` and `json.partial!('path', ...)`.
        POSITIONAL_PARTIAL = /\bjson\.partial!\s*\(?\s*['"]([^'"]+)['"]/

        # A literal `partial:` (or `:partial =>`) option on any `json.*` call.
        PARTIAL_OPTION = /\bjson\.\w+!?#{CALL_ARGUMENTS}(?:\bpartial:|:partial\s*=>)\s*['"]([^'"]+)['"]/

        # A Ruby expression where a partial path is expected: a method call
        # or an object reference such as `@order.customer`. The lookahead
        # keeps a keyword like `partial:` from matching as an expression.
        RUNTIME_EXPRESSION = '(@?[a-z_]\w*(?:\.\w+)*)(?![\w:])(\()?'

        # `json.partial! <expression>` as the first argument.
        POSITIONAL_RUNTIME_PARTIAL = /\bjson\.partial!\s*\(?\s*#{RUNTIME_EXPRESSION}/

        # `partial: <expression>` on any `json.*` call.
        RUNTIME_PARTIAL_OPTION = /\bjson\.\w+!?#{CALL_ARGUMENTS}\bpartial:\s*#{RUNTIME_EXPRESSION}/

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
          [POSITIONAL_PARTIAL, PARTIAL_OPTION].each do |pattern|
            source.scan(pattern) { |(name)| partials << name }
          end
          partials.to_a
        end

        # A runtime expression followed by `(` is a helper call; anything
        # else is treated as an object. A paren-less helper call with
        # arguments is therefore recorded as an object; the name is kept.
        #
        # @see Base#scan_unresolved_partials
        def scan_unresolved_partials(source)
          references = [POSITIONAL_RUNTIME_PARTIAL, RUNTIME_PARTIAL_OPTION].flat_map do |pattern|
            source.scan(pattern).map do |expression, call_paren|
              { kind: call_paren ? 'helper' : 'object', name: expression }
            end
          end
          references.uniq
        end

        private

        # @see Erb#partial_extension
        def partial_extension
          '.json.jbuilder'
        end
      end
    end
  end
end
