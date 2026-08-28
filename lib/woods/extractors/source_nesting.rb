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
        file_path = File.expand_path(file_path.to_s)
        root, owner, foreign_root = managed_root_for(file_path)
        return nil unless root

        return loader_expected_cpath(file_path) if owner == :loader
        return foreign_loader_constant_path(file_path, root, foreign_root) if owner == :foreign_loader

        local_managed_constant_path(file_path, root)
      end

      # The constant path the active main loader expects for +file_path+,
      # asked through the loader's own API so its inflector, namespace
      # collapse, and ignore rules decide (a custom `api => API` inflection
      # must win over the local camelizer). Available on Zeitwerk 2.6.4+;
      # nil — unmanaged — when the loader's API is older, declines the
      # file, or cannot derive a name. A decline is authoritative: the
      # local camelizer must not rescue it.
      #
      # @param file_path [String] Expanded absolute path to the file
      # @return [String, nil]
      def loader_expected_cpath(file_path)
        loader = main_loader
        return nil unless loader.respond_to?(:cpath_expected_at)

        loader.cpath_expected_at(file_path)
      rescue StandardError
        nil
      end

      # The local path-to-constant convention. Reserved for roots with no
      # loader to ask: the offline stand-in ({MANAGED_PATH_PATTERN}).
      #
      # @param file_path [String] Expanded absolute path to the file
      # @param root [String] The managed root the path is relative to
      # @return [String]
      def local_managed_constant_path(file_path, root)
        relative = file_path[root.length..].to_s.sub(/\.rb\z/, '')
        relative.split('/').reject(&:empty?).map { |segment| camelize_segment(segment) }.join('::')
      end

      # Constant path for a copied/multi-worktree file whose active root is
      # governed by the boot loader's root shape. Prefer the loader API by
      # mapping the active file onto the corresponding boot-loader root; when
      # the file exists only in the copy, keep the loader's inflector instead
      # of falling back to Woods' default camelizer.
      #
      # @param file_path [String] Expanded absolute path to the file
      # @param root [String] Active managed root the path is relative to
      # @param foreign_root [String, nil] Matching managed root from loader.dirs
      # @return [String]
      def foreign_loader_constant_path(file_path, root, foreign_root)
        mapped = foreign_root && mapped_foreign_path(file_path, root, foreign_root)
        expected = loader_expected_cpath(mapped) if mapped
        expected || inflected_managed_constant_path(file_path, root)
      end

      # @param file_path [String] Expanded absolute path under the active root
      # @param root [String] Active managed root
      # @param foreign_root [String] Matching boot-loader managed root
      # @return [String]
      def mapped_foreign_path(file_path, root, foreign_root)
        relative = file_path[root.length..].to_s
        File.join(foreign_root, relative)
      end

      # The path-to-constant convention using the active loader's inflector.
      # This is for copied-only foreign-root files where +cpath_expected_at+
      # has no real boot-path file to resolve, but the loader's configured
      # basename rules still govern (`api` => +API+).
      #
      # @param file_path [String] Expanded absolute path to the file
      # @param root [String] The managed root the path is relative to
      # @return [String]
      def inflected_managed_constant_path(file_path, root)
        relative = file_path[root.length..].to_s.sub(/\.rb\z/, '')
        segments = relative.split('/').reject(&:empty?)
        current = root.chomp('/')
        segments.map do |segment|
          current = File.join(current, segment)
          loader_camelize(segment, current)
        end.join('::')
      end

      # @param segment [String] Path segment without extension
      # @param abspath [String] Absolute path passed to Zeitwerk inflectors
      # @return [String]
      def loader_camelize(segment, abspath)
        loader = main_loader
        inflector = loader.respond_to?(:inflector) ? loader.inflector : nil
        return camelize_segment(segment) unless inflector.respond_to?(:camelize)

        begin
          inflector.camelize(segment, abspath)
        rescue ArgumentError
          inflector.camelize(segment)
        end
      rescue StandardError
        camelize_segment(segment)
      end

      # The managed root directory containing +file_path+, if any, with the
      # authority that vouches for it.
      #
      # When a Rails autoloader is up, its directory list is the authority
      # for the files it claims. For a file it does NOT claim, the
      # non-claim stays authoritative whenever the loader demonstrably
      # belongs to the active root (any loader directory under it) or
      # reports an empty set (classic mode): unmanaged. Only when every
      # loader root belongs to a DIFFERENT tree — copied-app and
      # multi-worktree extractions, where the loader belongs to the boot
      # root while Rails.root is repointed per slot — does the root-relative
      # `app/<kind>/` shape under the active root govern, still using the
      # foreign loader's inflector. No broad trust of paths that merely look
      # like app trees. When no autoloader information exists at all (no Rails, a spec stub),
      # {MANAGED_PATH_PATTERN} stands in offline.
      #
      # @param file_path [String] Absolute path to the source file
      # @return [Array(String, Symbol), nil] `[root, owner]` with owner
      #   +:loader+ or +:convention+, or nil when the file is unmanaged
      def managed_root_for(file_path)
        file_path = File.expand_path(file_path)
        loader = main_loader
        unless loader
          root = MANAGED_PATH_PATTERN.match(file_path)&.captures&.first
          return root ? [root, :convention] : nil
        end

        dirs = Array(loader.dirs).map { |dir| File.expand_path(dir.to_s.chomp('/')) }

        claimed = dirs.find { |dir| file_path.start_with?("#{dir}/") }
        return [claimed, :loader] if claimed

        active = active_root
        return nil unless active
        return nil if dirs.any? { |dir| dir.start_with?("#{active}/") }
        return nil if dirs.empty?

        active_root_managed_for(file_path, active, dirs)
      end

      # Root-relative managed root for a file the autoloader does not
      # claim, when the loader's roots all belong to another tree: the
      # conventional `app/<kind>/` shape under the ACTIVE extraction root,
      # or nil when the file sits outside it.
      #
      # @param file_path [String] Absolute path to the source file
      # @param active [String] Expanded active extraction root
      # @param dirs [Array<String>] Foreign loader roots
      # @return [Array(String, Symbol, String), nil] `[root, :foreign_loader,
      #   foreign_root]`, or nil
      def active_root_managed_for(file_path, active, dirs)
        return nil unless file_path.start_with?("#{active}/")

        shape = file_path[active.length..].to_s.match(%r{\A(/app/[^/]+/)})
        return nil unless shape

        root = "#{active}#{shape[1]}"
        suffix = shape[1].chomp('/')
        foreign_root = dirs.find { |dir| dir.end_with?(suffix) }

        [root, :foreign_loader, foreign_root]
      end

      # The active extraction root, expanded: the boot root in a normal
      # extraction, the repointed root in a copied or multi-worktree slot.
      #
      # @return [String, nil]
      def active_root
        return nil unless defined?(Rails) && Rails.respond_to?(:root)

        root = Rails.root
        root && File.expand_path(root.to_s)
      rescue StandardError
        nil
      end

      # The main Rails autoloader, or nil when there is none to consult
      # (no Rails, a spec stub). In classic mode the loader exists with an
      # empty directory list — an authoritative empty set.
      #
      # @return [Zeitwerk::Loader, nil]
      def main_loader
        return nil unless defined?(Rails) && Rails.respond_to?(:autoloaders)

        autoloaders = Rails.autoloaders
        return nil unless autoloaders.respond_to?(:main)

        main = autoloaders.main
        main.respond_to?(:dirs) ? main : nil
      rescue StandardError
        nil
      end

      # Camelize one path segment the way Zeitwerk's default inflector
      # treats conventional names: `payment` → +Payment+, `fee_schedule` →
      # +FeeSchedule+. Kept local so the scanner stays free of ActiveSupport.
      # It diverges from Zeitwerk on all-caps segments and cannot honor a
      # custom inflector (e.g. `api` configured as +API+): the mismatch only
      # fails the governed match, which falls back to the source parser —
      # governance is lost, an identifier is never wrong.
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
