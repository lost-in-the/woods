# frozen_string_literal: true

require 'set'
require_relative 'js_tokenizer'

module Woods
  module Extractors
    # What one JavaScript/TypeScript file declares, read from its token stream.
    #
    # A single forward pass with bounded lookahead: imports and their local
    # bindings, exports, Stimulus registrations and loaders, Alpine data and
    # store registrations, `window` function globals, and custom element tags
    # (Stencil `@Component` and `customElements.define`). Nothing here looks at
    # another file; {JsModuleRegistry} resolves names across files.
    #
    # @example
    #   facts = JsModuleFacts.parse('import d from "./dropdown"; Alpine.data("dropdown", d)')
    #   facts.alpine_registrations # => [{ kind: "alpine_data", name: "dropdown", target: "d" }]
    #   facts.bindings             # => { "d" => ["./dropdown", "default"] }
    class JsModuleFacts
      STIMULUS_PACKAGES = %w[@hotwired/stimulus stimulus].freeze
      STIMULUS_RECEIVER = /application|stimulus|\Aapp\z/i
      EXPORT_MODIFIERS = %w[declare abstract async].freeze
      EXPORT_DECLARATIONS = %w[const let var function class enum interface type namespace].freeze
      # Never the name of a value: an identifier here starts an expression.
      EXPRESSION_KEYWORDS = %w[function async class new await typeof void].freeze
      # How far a `@Component({ ... })` options object is read.
      DECORATOR_TOKEN_LIMIT = 400
      # Identifier => the method that reads the construct it starts.
      IDENTIFIER_HANDLERS = {
        'Alpine' => :scan_alpine, 'customElements' => :scan_define, 'import' => :scan_import,
        'export' => :scan_export, 'require' => :scan_require, 'module' => :scan_module_exports,
        'window' => :scan_window, 'eagerLoadControllersFrom' => :scan_loader,
        'lazyLoadControllersFrom' => :scan_loader, 'const' => :scan_declaration, 'let' => :scan_declaration,
        'var' => :scan_declaration, 'function' => :scan_declaration, 'class' => :scan_declaration
      }.freeze
      # Constructs that are still read after a dot (`window.Alpine.data`).
      MEMBER_HANDLERS = %i[scan_alpine scan_define].freeze
      OPENERS = ['{', '(', '['].freeze
      CLOSERS = ['}', ')', ']'].freeze

      # @return [Hash{String => Array(String, String)}] local name => [specifier, imported name]
      attr_reader :bindings
      # @return [Hash{String => Array(String, String)}] exported name => [specifier, imported name]
      attr_reader :reexports
      # @return [String, nil] name of the default export, when it has one
      attr_reader :default_export
      # @return [Array<Hash>] +{ function:, under: }+ per controller loader call
      attr_reader :stimulus_loaders
      # @return [Array<Hash>] +{ kind:, name:, target: }+; target is an identifier or nil when inline
      attr_reader :alpine_registrations
      # @return [Array<Hash>] +{ tag:, source:, target: }+
      attr_reader :custom_elements

      # @param source [String] file contents
      # @return [JsModuleFacts]
      def self.parse(source)
        new(JsTokenizer.tokens(source)).scan
      end

      # @param tokens [Array<Array(Symbol, String)>] {JsTokenizer} output
      def initialize(tokens)
        @tokens = tokens
        @imports = {}
        @bindings = {}
        @reexports = {}
        @named_exports = Set.new
        @default_export = nil
        @has_default = false
        @registrations = []
        @stimulus_loaders = []
        @alpine_registrations = []
        @globals = []
        @custom_elements = []
        @declared = Set.new
        @superclasses = Set.new
        @decorator_read_until = 0
      end

      # @return [self]
      def scan
        index = 0
        index = step(index) while index < @tokens.size
        self
      end

      # @return [Array<Hash>] +{ specifier:, names:, kind: }+ sorted by specifier, then kind
      def imports
        @imports.map { |(specifier, kind), names| { specifier: specifier, names: names.sort, kind: kind } }
                .sort_by { |entry| [entry[:specifier], entry[:kind]] }
      end

      # @return [Array<String>] sorted
      def named_exports
        @named_exports.sort
      end

      # @return [Boolean]
      def default_export?
        @has_default
      end

      # @return [Array<Hash>] +{ name:, target: }+ for calls that look like Stimulus
      def stimulus_registrations
        @registrations.filter_map do |entry|
          next unless stimulus_import? || entry[:receiver].to_s.match?(STIMULUS_RECEIVER)

          { name: entry[:name], target: entry[:target] }
        end
      end

      # @return [Array<Hash>] +{ name:, target: }+; target is nil for an inline function
      def globals
        @globals.select { |entry| entry[:target].nil? || known_name?(entry[:target]) }
      end

      # @return [Boolean] whether the file subclasses Stimulus's Controller
      def stimulus_controller_class?
        stimulus_import? && @superclasses.include?('Controller')
      end

      private

      def step(index)
        type, value = @tokens[index]
        return scan_identifier(index, value) if type == :ident
        return scan_decorator(index) if type == :punct && value == '@'

        scan_register(index) if type == :punct && value == '.'
        index + 1
      end

      def scan_identifier(index, value)
        handler = IDENTIFIER_HANDLERS[value]
        return index + 1 if handler.nil?
        # `foo.import(...)` and `registry.class` are member accesses, not keywords.
        return index + 1 if punct?(index - 1, '.') && index.positive? && !MEMBER_HANDLERS.include?(handler)

        send(handler, index)
      end

      # ── Imports ────────────────────────────────────────────────────────

      def scan_import(index)
        cursor = index + 1
        return cursor if punct?(cursor, '.')
        return scan_call_import(cursor, 'dynamic') if punct?(cursor, '(')
        return add_import(string(cursor), [], 'static') && (cursor + 1) if string?(cursor)

        cursor += 1 if type_modifier?(cursor)
        entries, specifier_index = clause(cursor)
        return [specifier_index, index + 1].max if entries.nil?

        specifier = string(specifier_index)
        add_import(specifier, entries.map(&:first), 'static')
        entries.each { |imported, local| @bindings[local] = [specifier, imported] if local }
        specifier_index + 1
      end

      def scan_require(index)
        punct?(index + 1, '(') ? scan_call_import(index + 1, 'require') : index + 1
      end

      def scan_call_import(open_index, kind)
        add_import(string(open_index + 1), [], kind) if string?(open_index + 1)
        open_index + 1
      end

      # `import type { A } from` is type-only; `import type from "./type"`
      # and `import type, { A } from` bind a default import named `type`.
      def type_modifier?(cursor)
        ident?(cursor, 'type') && !punct?(cursor + 1, ',') && !(ident?(cursor + 1, 'from') && string?(cursor + 2))
      end

      # Reads `Default, { a, b as c }, * as ns` up to `from "specifier"`.
      #
      # @return [Array(Array, Integer), Array(nil, Integer)] entries and the
      #   specifier's index, or nil and the index where reading stopped
      def clause(cursor)
        entries = []
        loop do
          return [entries, cursor + 1] if ident?(cursor, 'from') && string?(cursor + 1)

          if punct?(cursor, '*')
            named = ident?(cursor + 1, 'as') && ident?(cursor + 2)
            entries << ['*', named ? value(cursor + 2) : nil]
            cursor += named ? 3 : 1
          elsif punct?(cursor, '{')
            cursor, closed = named_list(cursor + 1, entries)
            return [nil, cursor] unless closed
          elsif punct?(cursor, ',')
            cursor += 1
          elsif ident?(cursor) && !%w[import export].include?(value(cursor))
            entries << ['default', value(cursor)]
            cursor += 1
          else
            return [nil, cursor]
          end
        end
      end

      # Reads `a, b as c, type D }`, appending `[first, second]` pairs.
      #
      # @return [Array(Integer, Boolean)] the index reading stopped at (after
      #   the closing brace on success) and whether the list was closed
      def named_list(cursor, entries)
        loop do
          return [cursor + 1, true] if punct?(cursor, '}')

          if punct?(cursor, ',')
            cursor += 1
          elsif ident?(cursor)
            cursor += 1 if ident?(cursor, 'type') && ident?(cursor + 1) && !ident?(cursor + 1, 'as')
            aliased = ident?(cursor + 1, 'as') && (ident?(cursor + 2) || string?(cursor + 2))
            entries << [value(cursor), aliased ? value(cursor + 2) : value(cursor)]
            cursor += aliased ? 3 : 1
          else
            return [cursor, false]
          end
        end
      end

      def add_import(specifier, names, kind)
        (@imports[[specifier, kind]] ||= Set.new).merge(names)
      end

      # ── Exports ────────────────────────────────────────────────────────

      def scan_export(index)
        cursor = index + 1
        return scan_default_export(cursor + 1) if ident?(cursor, 'default')

        cursor += 1 if ident?(cursor, 'type') && punct?(cursor + 1, '{')
        return scan_export_list(cursor) if punct?(cursor, '{')
        return scan_export_star(cursor) if punct?(cursor, '*')

        cursor += 1 while EXPORT_MODIFIERS.include?(value(cursor)) && ident?(cursor)
        if ident?(cursor) && EXPORT_DECLARATIONS.include?(value(cursor))
          name_index = punct?(cursor + 1, '*') ? cursor + 2 : cursor + 1
          @named_exports << value(name_index) if ident?(name_index)
        end
        cursor
      end

      def scan_default_export(cursor)
        @has_default = true
        start = cursor
        cursor += 1 if ident?(cursor, 'async') || ident?(cursor, 'abstract')
        if ident?(cursor, 'function')
          name_index = punct?(cursor + 1, '*') ? cursor + 2 : cursor + 1
          @default_export = value(name_index) if ident?(name_index)
        elsif ident?(cursor, 'class')
          if ident?(cursor + 1) && !%w[extends implements].include?(value(cursor + 1))
            @default_export = value(cursor + 1)
          end
        elsif plain_reference?(cursor)
          @default_export = value(cursor)
        end
        start
      end

      # A bare identifier, not the start of a call, member access or arrow.
      def plain_reference?(cursor)
        return false unless ident?(cursor) && !EXPRESSION_KEYWORDS.include?(value(cursor))

        following = @tokens[cursor + 1]
        following.nil? || following.first != :punct || [';', '}'].include?(following.last)
      end

      def scan_export_list(cursor)
        entries = []
        after, closed = named_list(cursor + 1, entries)
        return [after, cursor + 1].max unless closed

        specifier = string(after + 1) if ident?(after, 'from') && string?(after + 1)
        add_import(specifier, entries.map(&:first), 'reexport') if specifier
        entries.each { |local, exported| record_export(local, exported, specifier) }
        specifier ? after + 2 : after
      end

      def record_export(local, exported, specifier)
        @reexports[exported] = [specifier, local] if specifier
        return @named_exports << exported unless exported == 'default'

        @has_default = true
        @default_export = local unless specifier
      end

      def scan_export_star(cursor)
        entries, specifier_index = clause(cursor)
        return [specifier_index, cursor + 1].max if entries.nil?

        add_import(string(specifier_index), ['*'], 'reexport')
        entries.each { |entry| @named_exports << entry.last if entry.last }
        specifier_index + 1
      end

      def scan_module_exports(index)
        @has_default = true if punct?(index + 1, '.') && ident?(index + 2, 'exports') && punct?(index + 3, '=')
        index + 1
      end

      # ── Declarations ───────────────────────────────────────────────────

      def scan_declaration(index)
        keyword = value(index)
        name_index = punct?(index + 1, '*') ? index + 2 : index + 1
        named = ident?(name_index) && !(keyword == 'class' && value(name_index) == 'extends')
        @declared << value(name_index) if named
        if keyword == 'class'
          extends_index = named ? name_index + 1 : name_index
          @superclasses << value(extends_index + 1) if ident?(extends_index, 'extends') && ident?(extends_index + 1)
        end
        index + 1
      end

      # ── Stimulus ───────────────────────────────────────────────────────

      # `<receiver>.register("name", Identifier)`
      def scan_register(dot_index)
        return unless ident?(dot_index + 1, 'register') && punct?(dot_index + 2, '(') &&
                      string?(dot_index + 3) && punct?(dot_index + 4, ',') && ident?(dot_index + 5)

        receiver = ident?(dot_index - 1) && dot_index.positive? ? value(dot_index - 1) : nil
        @registrations << { name: string(dot_index + 3), target: value(dot_index + 5), receiver: receiver }
      end

      def scan_loader(index)
        if punct?(index + 1, '(') && string?(index + 2)
          @stimulus_loaders << { function: value(index), under: string(index + 2).delete_suffix('/') }
        end
        index + 1
      end

      def stimulus_import?
        @imports.each_key.any? do |specifier, _kind|
          STIMULUS_PACKAGES.any? do |package|
            specifier == package || specifier.start_with?("#{package}/", "#{package}-")
          end
        end
      end

      # ── Alpine ─────────────────────────────────────────────────────────

      # `Alpine.data("name", value)` and `Alpine.store("name", value)`
      def scan_alpine(index)
        kind = { 'data' => 'alpine_data', 'store' => 'alpine_store' }[value(index + 2)] if ident?(index + 2)
        if kind && punct?(index + 1, '.') && punct?(index + 3, '(') && string?(index + 4)
          target = punct?(index + 5, ',') ? value_reference(index + 6) : nil
          @alpine_registrations << { kind: kind, name: string(index + 4), target: target }
        end
        index + 1
      end

      # `window.name = function ...`, `window.name = () => ...`, `window.name = known`
      def scan_window(index)
        return index + 1 unless punct?(index + 1, '.') && ident?(index + 2) && punct?(index + 3, '=')

        start = index + 4
        if function_start?(start)
          @globals << { name: value(index + 2), target: nil }
        elsif plain_reference?(start)
          @globals << { name: value(index + 2), target: value(start) }
        end
        index + 1
      end

      def function_start?(cursor)
        punct?(cursor, '(') || ident?(cursor, 'function') || ident?(cursor, 'async') ||
          (ident?(cursor) && punct?(cursor + 1, '=>'))
      end

      # The identifier a registration hands over, or nil when the value is
      # written inline (a function, an arrow, an object, a class).
      def value_reference(cursor)
        return nil unless ident?(cursor) && !EXPRESSION_KEYWORDS.include?(value(cursor))
        return nil if punct?(cursor + 1, '=>')

        value(cursor)
      end

      def known_name?(name)
        @bindings.key?(name) || @declared.include?(name)
      end

      # ── Custom elements ────────────────────────────────────────────────

      # `customElements.define("tag", Identifier)`
      def scan_define(index)
        if punct?(index + 1, '.') && ident?(index + 2, 'define') && punct?(index + 3, '(') && string?(index + 4)
          target = punct?(index + 5, ',') ? value_reference(index + 6) : nil
          @custom_elements << { tag: string(index + 4), source: 'define', target: target }
        end
        index + 1
      end

      # Stencil's `@Component({ tag: "x-name", ... })`, top-level keys only.
      # A decorator inside another decorator's options is not read, which
      # keeps the lookahead from overlapping.
      def scan_decorator(index)
        return index + 1 if index < @decorator_read_until
        return index + 1 unless ident?(index + 1, 'Component') && punct?(index + 2, '(') && punct?(index + 3, '{')

        depth = 1
        cursor = index + 4
        limit = [cursor + DECORATOR_TOKEN_LIMIT, @tokens.size].min
        while cursor < limit && depth.positive?
          depth += nesting_change(cursor)
          if depth == 1 && ident?(cursor, 'tag') && punct?(cursor + 1, ':') && string?(cursor + 2)
            @custom_elements << { tag: string(cursor + 2), source: 'stencil', target: nil }
          end
          cursor += 1
        end
        @decorator_read_until = cursor
        index + 1
      end

      def nesting_change(cursor)
        type, text = @tokens[cursor]
        return 0 unless type == :punct
        return 1 if OPENERS.include?(text)

        CLOSERS.include?(text) ? -1 : 0
      end

      # ── Token access ───────────────────────────────────────────────────

      def ident?(index, name = nil)
        type, text = @tokens[index]
        type == :ident && (name.nil? || text == name)
      end

      def punct?(index, text)
        type, actual = @tokens[index]
        type == :punct && actual == text
      end

      def string?(index)
        type, text = @tokens[index]
        type == :string && !text.nil?
      end

      def string(index)
        @tokens[index].last
      end

      def value(index)
        token = @tokens[index]
        token&.last
      end
    end
  end
end
