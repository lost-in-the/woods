# frozen_string_literal: true

require 'set'
require 'strscan'
require_relative 'helper_catalog'
require_relative '../source_file'

module Woods
  module Extractors
    # Finds calls to application helper methods in Ruby source and turns
    # them into dependency edges.
    #
    # Rails mixes every helper module into every view, so a template calls
    # `pretty_date(x)` without naming `DateHelper`. {.method_calls} is the
    # scan half of closing that gap: one token pass over a source against a
    # Set of catalog names. {.resolve} is the other half: it asks the
    # {HelperCatalog} which module or controller each called name belongs to.
    # {.annotate} does both for a class-based unit. Each token is read once, and every pattern is
    # anchored at the scanner position, so the pass is linear in the source.
    #
    # The pass is lexical, not a parse. It reports a name when it appears as
    # a receiverless call, or as a call on the `helpers` proxy. It skips a
    # name used as a symbol, a hash label, a method called on another
    # receiver, a method definition, string or heredoc text, a comment, or a local
    # (an assignment target, a block parameter, a `local_assigns` or
    # `defined?` probe, or a local the caller names).
    class HelperCallScan
      # A plain identifier, with a trailing `?` or `!` unless that
      # character starts `!=` or `?=`.
      IDENTIFIER = /[A-Za-z_]\w*+(?:[?!](?!=))?/

      SPACE = /\s++/
      COMMENT = /#[^\n]*+/
      SINGLE_QUOTED = /'(?:[^'\\]++|\\.)*+'/m
      WORD_ARRAY_OPEN = /%[wWiI][\[({]/
      WORD_ARRAY = /%[wWiI](?:\[[^\]]*+\]|\([^)]*+\)|\{[^}]*+\})/
      # Tokens that are never a call and never a receiver: a range operator,
      # a symbol, an instance/class/global variable, a number.
      INERT = /\.{2,3}|:[A-Za-z_]\w*+[?!=]?+|@@?+[A-Za-z_]\w*+|\$\w++|\d\w*+(?:\.\d\w*+)?/
      SCOPE = /::/
      DOT = /&?\./
      # A `name:` label: one colon, not `::`.
      LABEL = /:(?!:)/
      # `=` and operator-assignment, but not `==`, `=~`, or `=>`.
      ASSIGNMENT = %r{[ \t]*+(?:\|\||&&|[-+*/%])?=(?![=~>])}
      BLOCK_PARAMETERS = /\|([^|\n]*+)\|/
      LOCAL_ASSIGNS_KEY = /(?:\[|\.(?:fetch|key\?|dig)\(?)\s*+:([A-Za-z_]\w*+)/
      DEFINED_OPERAND = /\s*+\(?\s*+([a-z_]\w*+)/
      # `<<~NAME`, `<<-NAME`, or `<<NAME` with an all-caps name (so `a <<b`
      # stays a shift), optionally quoted. Captures 2 or 4 hold the name.
      HEREDOC = /<<[~-](["'`]?)([A-Za-z_]\w*+)\1|<<(["'`]?)([A-Z][A-Z0-9_]*+)\3/
      # The end of a line of code, with any trailing comment.
      LINE_END = /[ \t]*+(?:#[^\n]*+)?\n/
      INTERPOLATION = /#\{/
      ESCAPE = /\\./m
      # Text of an interpolating literal up to the next character that can
      # end it, escape it, or open an interpolation.
      STRING_TEXT = { '"' => /[^"\\#]++/, '`' => /[^`\\#]++/ }.freeze

      # The view-context proxy controllers and components call helpers on.
      HELPERS_PROXY = 'helpers'
      HELPERS_DELEGATION = /\bto:\s*+:helpers\b/
      SYMBOL_NAME = /:([A-Za-z_]\w*+[?!]?)/

      class << self
        # @param code [String] Ruby source (for a template: its Ruby regions)
        # @param names [Set<String>] catalog method names to look for
        # @param locals [Enumerable<String>] names known to be locals
        # @return [Hash{Symbol => Array<String>}] `{ bare:, explicit: }`,
        #   each sorted: receiverless calls and `helpers.` calls
        def method_calls(code, names, locals: [])
          new(code, names, locals).method_calls
        end

        # Turn scanned calls into edges and metadata.
        #
        # A template (no `includer`) resolves every call through `context`,
        # its owning controller or mailer. A class resolves `helpers.` calls
        # the same way, and a receiverless call only when the class includes
        # the helper module that defines the name.
        #
        # @param catalog [HelperCatalog]
        # @param calls [Hash{Symbol => Array<String>}] {.method_calls} result
        # @param context [Class, nil] controller or mailer whose helpers apply
        # @param includer [Class, nil] the class whose source was scanned
        # @return [Hash] `{ dependencies: Array<Hash>, metadata: Hash }`.
        #   Metadata keys, each present only when non-empty: `:helper_calls`
        #   (module => names), `:helper_method_calls` (controller => names),
        #   `:ambiguous_helper_calls` (name => candidate modules).
        def resolve(catalog, calls, context: nil, includer: nil)
          resolved = calls[:explicit].to_h { |name| [name, catalog.resolve(name, context)] }
          calls[:bare].each do |name|
            edges = includer ? catalog.resolve_included(name, includer) : catalog.resolve(name, context)
            resolved[name] = (resolved.fetch(name, []) + edges).uniq
          end
          { dependencies: dependencies(resolved), metadata: metadata(resolved) }
        end

        # Add a {.resolve} result to a unit. A unit with no helper calls is
        # left untouched, key for key.
        #
        # @param unit [ExtractedUnit]
        # @param resolution [Hash] {.resolve} result
        # @return [ExtractedUnit]
        def apply(unit, resolution)
          unit.dependencies = (unit.dependencies + resolution[:dependencies]).uniq do |dependency|
            dependency.values_at(:type, :target, :via)
          end
          unit.metadata = unit.metadata.merge(resolution[:metadata])
          unit
        end

        # Entry point for the class-based extractors (controllers, mailers,
        # Phlex components, view components): scan the unit's source, and a
        # view component's sidecar template, then add the helper edges. A
        # controller or mailer also lists the helper methods it declares.
        #
        # @param extractor [Object] the calling extractor; it carries the
        #   catalog for the run
        # @param unit [ExtractedUnit]
        # @param klass [Class] the class the unit describes
        # @return [ExtractedUnit]
        def annotate(extractor, unit, klass)
          catalog = catalog_for(extractor)
          return unit if catalog.names.empty?

          calls = class_calls(catalog, unit)
          context = klass.respond_to?(:_helpers) ? klass : nil
          apply(unit, resolve(catalog, calls, context: context, includer: klass))
          declared = catalog.declared_helper_methods(klass)
          unit.metadata = unit.metadata.merge(helper_methods: declared) if declared.any?
          unit
        end

        private

        def catalog_for(extractor)
          extractor.instance_variable_get(:@helper_catalog) ||
            extractor.instance_variable_set(:@helper_catalog, HelperCatalog.new)
        end

        def class_calls(catalog, unit)
          source = unit.source_code.to_s
          calls = method_calls(source, catalog.names)
          sidecar = sidecar_calls(catalog, unit.metadata[:sidecar_template])
          { bare: calls[:bare] | sidecar[:bare],
            explicit: (calls[:explicit] | sidecar[:explicit] | proxy_declarations(source, catalog.names)).sort }
        end

        # Names a class routes to the helpers proxy by declaration:
        # `use_helpers :a, :b` and `delegate :a, to: :helpers`.
        def proxy_declarations(source, names)
          source.each_line.flat_map do |line|
            next [] unless line.include?('use_helpers') ||
                           (line.include?('delegate') && line.match?(HELPERS_DELEGATION))

            line.scan(SYMBOL_NAME).flatten.select { |name| names.include?(name) }
          end.uniq
        end

        def sidecar_calls(catalog, relative_path)
          path = relative_path && File.join(catalog.root, relative_path)
          engine = path && sidecar_engines.find { |candidate| candidate.handles?(path) }
          return { bare: [], explicit: [] } unless engine && File.file?(path)

          engine.scan_method_calls(SourceFile.read(path), catalog.names)
        end

        def sidecar_engines
          require_relative 'view_engines/haml'
          @sidecar_engines ||= [ViewEngines::Erb.new, ViewEngines::Haml.new]
        end

        def dependencies(resolved)
          resolved.values.flatten(1).map { |edge| edge.slice(:type, :target, :via) }.uniq
                  .sort_by { |edge| [edge[:via].to_s, edge[:target]] }
        end

        def metadata(resolved)
          { helper_calls: names_by_target(resolved, :helper_call),
            helper_method_calls: names_by_target(resolved, :helper_method),
            ambiguous_helper_calls: ambiguous(resolved) }.reject { |_key, value| value.empty? }
        end

        def names_by_target(resolved, via)
          pairs = resolved.flat_map do |name, edges|
            edges.select { |edge| edge[:via] == via }.map { |edge| [edge[:target], name] }
          end
          pairs.group_by(&:first).sort.to_h { |target, group| [target, group.map(&:last).sort] }
        end

        def ambiguous(resolved)
          resolved.sort.each_with_object({}) do |(name, edges), found|
            targets = edges.select { |edge| edge[:ambiguous] }.map { |edge| edge[:target] }
            found[name] = targets.sort if targets.any?
          end
        end
      end

      # @param code [String]
      # @param names [Set<String>]
      # @param locals [Enumerable<String>]
      def initialize(code, names, locals)
        @scanner = StringScanner.new(code.valid_encoding? ? code : code.scrub(' '))
        @names = names
        @locals = locals.to_set
        @bare = Set.new
        @explicit = Set.new
        # Open literals, innermost last. A String frame is the terminator of
        # an interpolating literal; an Integer frame is the brace depth of
        # the code inside one of its interpolations (or of the source itself).
        @frames = [0]
        @previous = nil
        # Terminators of heredocs opened on the current line, in order.
        @heredocs = []
      end

      # @return [Hash{Symbol => Array<String>}]
      def method_calls
        @frames.last.is_a?(String) ? scan_string_text : scan_code until @scanner.eos?
        { bare: (@bare - @locals).sort, explicit: @explicit.sort }
      end

      private

      def scan_code
        return heredoc_bodies if @heredocs.any? && @scanner.skip(LINE_END)
        return if @scanner.skip(SPACE) || @scanner.skip(COMMENT)

        previous = @previous
        @previous = nil
        if (word = @scanner.scan(IDENTIFIER)) then identifier(word, previous)
        elsif @scanner.skip(INERT) then nil
        elsif @scanner.skip(DOT) then @previous = previous == HELPERS_PROXY ? :helpers_dot : :dot
        elsif @scanner.skip(SCOPE) then @previous = :dot
        else punctuation(previous)
        end
      end

      def identifier(word, previous)
        return if previous == :def
        return @previous = :def if word == 'def'
        return @previous = :block_open if word == 'do'
        return @explicit << word if previous == :helpers_dot && @names.include?(word)
        return @previous = word if previous == :dot
        return if @scanner.match?(LABEL)
        return @locals << word if @scanner.match?(ASSIGNMENT)

        probe_locals(word)
        @previous = word
        @bare << word if @names.include?(word)
      end

      def probe_locals(word)
        pattern = { 'local_assigns' => LOCAL_ASSIGNS_KEY, 'defined?' => DEFINED_OPERAND }[word]
        @locals << @scanner[1] if pattern && @scanner.scan(pattern)
      end

      def punctuation(previous)
        case @scanner.peek(1)
        when "'" then quoted(SINGLE_QUOTED)
        when '%' then @scanner.match?(WORD_ARRAY_OPEN) ? quoted(WORD_ARRAY) : @scanner.getch
        when '"', '`' then @frames << @scanner.getch
        when '<' then @scanner.skip(HEREDOC) ? @heredocs << (@scanner[2] || @scanner[4]) : @scanner.getch
        when '{' then open_brace
        when '}' then close_brace
        when '|' then block_parameters(previous)
        else @scanner.getch
        end
      end

      # Skip a non-interpolating literal. One left open runs to the end of
      # the source, so the scan ends there rather than retrying the same
      # search from every later quote.
      def quoted(pattern)
        @scanner.skip(pattern) || @scanner.terminate
      end

      # Skip the bodies of the heredocs the finished line opened. A body
      # with no terminator line runs to the end of the source.
      def heredoc_bodies
        @heredocs.shift(@heredocs.size).each do |terminator|
          @scanner.skip_until(/^[ \t]*+#{Regexp.escape(terminator)}[ \t]*+$/) || @scanner.terminate
        end
      end

      def open_brace
        @scanner.getch
        @frames[-1] += 1
        @previous = :block_open
      end

      def close_brace
        @scanner.getch
        if @frames.last.zero?
          @frames.pop if @frames.size > 1
        else
          @frames[-1] -= 1
        end
      end

      def block_parameters(previous)
        return @scanner.getch unless previous == :block_open && @scanner.skip(BLOCK_PARAMETERS)

        @scanner[1].scan(IDENTIFIER) { |name| @locals << name }
      end

      def scan_string_text
        terminator = @frames.last
        if @scanner.skip(STRING_TEXT.fetch(terminator)) || @scanner.skip(ESCAPE) then nil
        elsif @scanner.skip(INTERPOLATION) then @frames << 0
        elsif @scanner.getch == terminator then @frames.pop
        end
      end
    end
  end
end
