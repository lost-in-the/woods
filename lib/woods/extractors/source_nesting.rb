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

      # The offline stand-in for a Zeitwerk autoload root: the last `app/`
      # directory segment in a path. When no Rails autoloader is up there is
      # no loader to ask, so file-path governance falls back to the same
      # convention the runtime loader follows — everything under
      # `app/<kind>/` maps to constants, e.g.
      # `app/services/domain/container/parser.rb` → +Domain::Container::Parser+.
      MANAGED_PATH_PATTERN = %r{\A(.*/app/[^/]+/)}

      # Inner module names that hold mixin plumbing (ActiveSupport::Concern's
      # ClassMethods, the classic included-hook InstanceMethods) — never the
      # unit a file is named for.
      MIXIN_INNER_MODULES = %w[ClassMethods InstanceMethods].freeze

      # Matches a line-leading `end` that closes a block, whether it stands
      # alone or is followed by a method chain (`end.freeze`, `end.join(x)`)
      # or a closing delimiter (`end)`, `end]`, `end,`). An exact `== 'end'`
      # check misses all of those, so a line like `LIST = %w[a b].map do |x|
      # x end.freeze` pushed a stack frame on `do` that its own `end` never
      # popped.
      END_LINE = /\Aend\b/

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
        each_declaration(source) do |kind, _name, qualified|
          return qualified if kind == 'class'
        end

        nil
      end

      # Zeitwerk-governed name for a file's primary constant (finding G-1).
      #
      # A file under a managed autoload path is expected by Zeitwerk to
      # define the constant its path spells: `app/services/domain/container/
      # parser.rb` must define +Domain::Container::Parser+. The
      # source-derived parser ({#qualified_first_class_name}) returns at the
      # FIRST class declaration, so a file whose namespaces are written as
      # classes (`module Domain; class Container; class Parser`) named the
      # unit after the wrapper (+Domain::Container+). Every sibling under the
      # same wrapper then collided on one identifier, and same-type dedup
      # silently dropped all but one.
      #
      # This method computes the expected constant path — from
      # +Rails.autoloaders.main+ when a Rails autoloader is up, from the
      # same path-to-constant convention offline otherwise — and returns the
      # first declaration (class or module) whose qualified name equals it.
      # When the path is not managed, or no declaration matches (an
      # unconventional file), it returns nil and the caller falls back to
      # {#qualified_first_class_name}: pre-G-1 behavior for everything the
      # convention cannot vouch for.
      #
      # @param file_path [String, Pathname] Path to the source file
      # @param source [String] Ruby source code
      # @return [String, nil] The Zeitwerk-expected constant name, or nil
      #   when the path is unmanaged or the source does not declare it
      def governed_class_name(file_path, source)
        expected = managed_constant_path(file_path.to_s)
        return nil unless expected

        first_declaration_named(expected, source)
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

      # Yield every module/class declaration with its position-aware
      # qualified name. The stack discipline is the one documented on the
      # module: declarations open frames, {#block_opener?} opens anonymous
      # (depth-only) frames, and {END_LINE}-matching lines pop them.
      #
      # @param source [String] Ruby source code
      # @yieldparam kind [String] 'module' or 'class'
      # @yieldparam name [String] The declared (possibly compact) name
      # @yieldparam qualified [String] Enclosing stack joined with the name
      # @return [void]
      def each_declaration(source)
        stack = []

        each_significant_line(source) do |stripped|
          if (decl = DECLARATION_PATTERN.match(stripped))
            yield decl[1], decl[2], (stack.compact << decl[2]).join('::')

            # A self-terminated declaration (`module Foo; end`) is not an
            # opener under the house pattern and encloses nothing.
            stack << decl[2] if block_opener?(stripped)
          elsif stripped.match?(END_LINE)
            stack.pop
          elsif block_opener?(stripped)
            stack << nil # anonymous block (do/def/if/...): depth only, no name
          end
        end
      end

      # First declaration whose qualified name equals +expected+.
      #
      # @param expected [String] The Zeitwerk-expected constant path
      # @param source [String] Ruby source code
      # @return [String, nil] The matching qualified declaration name
      def first_declaration_named(expected, source)
        each_declaration(source) do |_kind, _name, qualified|
          return qualified if qualified == expected
        end

        nil
      end

      # Constant path the file's position under a managed root expects.
      #
      # @param file_path [String] Absolute path to the source file
      # @return [String, nil] Camelized constant path, or nil when the file
      #   is not under a managed root
      def managed_constant_path(file_path)
        root = managed_root_for(file_path)
        return nil unless root

        relative = file_path[root.length..].to_s.sub(/\.rb\z/, '')
        relative.split('/').reject(&:empty?).map { |segment| camelize_segment(segment) }.join('::')
      end

      # The managed root directory containing +file_path+, if any.
      #
      # When a Rails autoloader is up its directory list is the authority: a
      # file it does not claim is not governed, even if it happens to sit
      # under an `app/` segment (lib/, spec/, engines' wheels...). Only when
      # no autoloader information exists at all does {MANAGED_PATH_PATTERN}
      # stand in offline.
      #
      # @param file_path [String] Absolute path to the source file
      # @return [String, nil] Absolute root ending in `/`, or nil
      def managed_root_for(file_path)
        dirs = autoload_root_dirs
        return dirs.find { |dir| file_path.start_with?("#{dir}/") } if dirs

        MANAGED_PATH_PATTERN.match(file_path)&.captures&.first
      end

      # Directories of the main Rails autoloader, or nil when there is no
      # autoloader to consult (no Rails, classic mode, a stub in specs).
      # A non-nil empty array is meaningful — Rails is present in classic
      # mode and manages nothing.
      #
      # @return [Array<String>, nil]
      def autoload_root_dirs
        return nil unless defined?(Rails) && Rails.respond_to?(:autoloaders)

        autoloaders = Rails.autoloaders
        return nil unless autoloaders.respond_to?(:main)

        main = autoloaders.main
        return nil unless main.respond_to?(:dirs)

        main.dirs.map { |dir| dir.to_s.chomp('/') }
      rescue StandardError
        nil
      end

      # Camelize one path segment the way Zeitwerk's default inflector
      # treats conventional names: `payment` → +Payment+, `fee_schedule` →
      # +FeeSchedule+. Kept local so the scanner stays free of ActiveSupport.
      #
      # @param segment [String]
      # @return [String]
      def camelize_segment(segment)
        segment.gsub(/(?:\A|_)([a-z])/) { Regexp.last_match(1).upcase }
      end

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
