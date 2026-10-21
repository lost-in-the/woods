# frozen_string_literal: true

require_relative 'constant_paths'

module Woods
  module Extractors
    # Resolves a constant reference the way Ruby does at its call site, against
    # the constants the booted application has loaded.
    #
    # The lookup order is Ruby's: each lexical scope's own constants,
    # innermost first; then the innermost scope's ancestors; then the top
    # level. The answer is the found constant's own `name`, never the
    # candidate string. `Shipment.const_get(:PingJob)` returns a top-level
    # `PingJob` through `Object`, and calling that `Shipment::PingJob` would
    # name a constant that does not exist.
    #
    # The rule itself is {ConstantPaths.resolve}; this is its name-only form
    # for reference scanning.
    module LexicalConstant
      # A constant segment starts with an uppercase letter.
      CONSTANT_HEAD = /\A[[:upper:]]/

      module_function

      # @param reference [String] the constant as written (`PingJob`,
      #   `Tasks::PingJob`)
      # @param nesting [Array<String>] enclosing scope names, innermost first
      # @param modules [Hash] memo shared across the references of one source
      # @return [String] the resolved constant's name, or +reference+ when it
      #   resolves to no class or module
      def resolve(reference, nesting, modules: {})
        return reference unless reference.match?(CONSTANT_HEAD)

        lookup = modules[:lookup] ||= SourceReferences::RuntimeLookup.new
        resolution = ConstantPaths.resolve(reference, nesting, lookup: lookup)
        resolution.status == :value ? reference : resolution.target
      rescue StandardError, ScriptError
        reference
      end
    end
  end
end
