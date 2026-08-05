# frozen_string_literal: true

module Woods
  module Extractors
    # Position-aware module/class nesting scanner for Ruby source text.
    #
    # Several extractors name their units by parsing declarations out of raw
    # source. The naive approaches — "first +class+ regex match" or "prepend
    # every +module+ in the file" — get nesting wrong (#174): they drop the
    # enclosing namespace (`module Billing; class Payment` indexed as bare
    # +Payment+), absorb sibling modules that closed before the class opened,
    # and let helper modules nested *inside* a class pollute the identifier.
    # Wrong identifiers collapse cross-namespace same-named classes onto one
    # graph node and leave edges targeting the real constant dangling.
    #
    # This module scans source line by line tracking nesting *by position*:
    # a stack of open +module+/+class+ declarations that pops on the matching
    # +end+, using the same depth-tracking discipline as
    # RakeTaskExtractor#block_opener? (the house pattern for what counts as a
    # block opener). Compact declarations (`class Billing::Payment`) keep
    # their qualified segments.
    #
    # The heuristic is regex-based, not an AST. Pathological constructs
    # (heredocs containing keywords, `x = if ...` assignments, keywords inside
    # string literals) can unbalance the depth count — the accepted house
    # tradeoff, shared with RakeTaskExtractor: declarations and their +end+s
    # pair up for conventionally formatted files.
    #
    # @example Qualifying the first class declaration
    #   qualified_first_class_name("module Billing\n  class Payment\n  end\nend")
    #   # => "Billing::Payment"
    #
    # @example Naming a concern by its outer module, not an inner mixin module
    #   qualified_outer_module_name("module Trackable\n  module ClassMethods\n  end\nend")
    #   # => "Trackable"
    #
    module SourceNesting
      # Matches a line-leading module/class declaration and captures the
      # keyword and the (possibly compact, `A::B`-style) constant name.
      # The constant must start uppercase, which also keeps `class << self`
      # from matching as a named declaration (it is still depth-tracked as an
      # anonymous block via {#block_opener?}).
      DECLARATION_PATTERN = /\A(module|class)\s+([A-Z]\w*(?:::[A-Z]\w*)*)/

      # Inner module names that hold mixin plumbing (ActiveSupport::Concern's
      # ClassMethods, the classic included-hook InstanceMethods) — never the
      # unit a file is named for.
      MIXIN_INNER_MODULES = %w[ClassMethods InstanceMethods].freeze

      # Fully-qualified name of the first +class+ declaration in the source.
      #
      # Enclosing modules still open at that position are joined with the
      # class's own name; compact-form segments are preserved. Sibling modules
      # that closed before the class opened, and modules nested after the
      # class, do not contribute — that positional accuracy is the point.
      #
      # @param source [String] Ruby source code
      # @return [String, nil] Qualified class name, or nil when the source
      #   contains no class declaration
      def qualified_first_class_name(source)
        stack = []

        each_significant_line(source) do |stripped|
          if (decl = DECLARATION_PATTERN.match(stripped))
            return (stack.compact << decl[2]).join('::') if decl[1] == 'class'

            # A self-terminated declaration (`module Foo; end`) is not an
            # opener under the house pattern and encloses nothing.
            stack << decl[2] if block_opener?(stripped)
          elsif stripped == 'end'
            stack.pop
          elsif block_opener?(stripped)
            stack << nil # anonymous block (do/def/if/...): depth only, no name
          end
        end

        nil
      end

      # Fully-qualified name of the file's primary module.
      #
      # Follows the initial chain of module declarations — each opening
      # directly inside the previous one, with only blank/comment lines
      # between — and returns the chain joined with `::`. Prelude lines
      # before the first module (requires, magic comments, guards) are
      # skipped. The chain stops at the first body content (methods,
      # `extend`, a class, a self-terminated inner module) and never descends
      # into mixin plumbing modules ({MIXIN_INNER_MODULES}), so `module
      # Trackable; module ClassMethods` names +Trackable+ while `module
      # Gateway; module Stripe; module Refundable` names
      # +Gateway::Stripe::Refundable+. This preserves the file-per-unit
      # assumption: one primary module per file, possibly wrapped in
      # namespace modules.
      #
      # @param source [String] Ruby source code
      # @return [String, nil] Qualified module name, or nil when the source
      #   opens no module
      def qualified_outer_module_name(source)
        chain = []

        each_significant_line(source) do |stripped|
          decl = DECLARATION_PATTERN.match(stripped)

          unless decl
            next if chain.empty? # prelude before any module (requires, guards)

            break # body content — the chain is complete
          end

          break unless decl[1] == 'module'
          break if decl[2].split('::').any? { |seg| MIXIN_INNER_MODULES.include?(seg) }

          unless block_opener?(stripped)
            # Self-terminated one-liner (`module Foo; end`): encloses nothing.
            # Before the chain starts it is a sibling prelude (skip it);
            # afterwards it is body content (chain complete).
            break unless chain.empty?

            next
          end

          chain << decl[2]
        end

        chain.empty? ? nil : chain.join('::')
      end

      # Check if a line opens a new block (do...end, def...end, etc.).
      #
      # Mirrors RakeTaskExtractor#block_opener? — the house pattern:
      # +if+/+unless+ only count when they start the line (standalone form),
      # not as trailing modifiers (e.g., `return if x`), and a line ending in
      # +end+ closed whatever it opened.
      #
      # @param stripped [String] Stripped line content
      # @return [Boolean]
      def block_opener?(stripped)
        return true if stripped.match?(/\b(do|def|case|begin|class|module|while|until|for)\b.*(?<!\bend)\s*$/)

        stripped.match?(/\A(if|unless)\b/)
      end

      private

      # Yield each non-blank, non-comment line of source, stripped.
      #
      # @param source [String] Ruby source code
      # @yieldparam stripped [String] Stripped significant line
      # @return [void]
      def each_significant_line(source)
        source.each_line do |line|
          stripped = line.strip
          next if stripped.empty? || stripped.start_with?('#')

          yield stripped
        end
      end
    end
  end
end
