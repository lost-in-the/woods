# frozen_string_literal: true

require_relative '../declaration_name'

module Woods
  module RubyAnalyzer
    # Shared helper for naming a class or module declaration in its lexical nesting.
    module FqnBuilder
      private

      # @param name [String] the declaration's constant path as written
      # @param nesting [Array<String>] enclosing qualified names, outermost first
      # @param names [Woods::DeclarationName] the declarations of this source so far
      # @return [String] the qualified name Ruby's constant lookup gives it
      def build_fqn(name, nesting, names)
        names.declare(name, nesting)
      end
    end
  end
end
