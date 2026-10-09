# frozen_string_literal: true

require 'strscan'

module Woods
  module Extractors
    # Pulls the Ruby out of a view template, one fragment per tag or script line.
    #
    # A component's sidecar template renders other components in Ruby that
    # sits between markup. The fragments returned here are that Ruby and
    # nothing else, so a syntax-tree scan ({RenderCallScan}) can read them:
    # text outside a tag, a template comment, and a filter body in another
    # language never reach it.
    #
    # A fragment is not a complete program. `render Row.new do |row|` and its
    # `end` arrive separately, and each is scanned on its own; the parser
    # recovers the call from the open block.
    #
    # Both readers are single token passes over the source with byte offsets.
    #
    # @example
    #   TemplateRubyFragments.call('<p><%= render Row.new %></p>', engine: :erb)
    #   # => [" render Row.new "]
    #
    module TemplateRubyFragments
      ERB_OPEN = /<%/
      ERB_CLOSE = /%>/
      # `<%=`, `<%==`, `<%-` after the opener, and the `-` of a `-%>` closer.
      ERB_LEADING_MARK = /\A(?:==?|-)/
      ERB_TRAILING_MARK = /-\z/

      # `%tag`, `.class`, `#id`, in any run.
      HAML_TAG_HEAD = /(?:[%.#][\w:-]++)++/
      # Self-closing and whitespace-removal marks between a tag and its script.
      HAML_TAG_MARKS = %r{[<>/]++}
      # `=`, `==`, `!=`, `&=`, `~` and `-`: the rest of the line is Ruby.
      HAML_SCRIPT = /(?:[!&]?={1,2}|~|-)[ \t]*+/
      HAML_FILTER = /\A:(\w++)\z/
      HAML_INDENT = /\A[ \t]*+/
      HAML_OPENERS = '{(['
      HAML_CLOSERS = '})]'

      module_function

      # @param source [String] template source
      # @param engine [Symbol] the view engine's name, as
      #   {ViewEngines::Base#name} reports it
      # @return [Array<String>] Ruby fragments in source order; empty for an
      #   engine whose templates are not markup with embedded Ruby
      def call(source, engine:)
        case engine
        when :erb then erb(source)
        when :haml then haml(source)
        else []
        end
      end

      # @param source [String]
      # @return [Array<String>]
      def erb(source)
        scanner = StringScanner.new(source)
        fragments = []
        while scanner.skip_until(ERB_OPEN)
          next if scanner.skip(/%/)

          comment = scanner.skip(/#/)
          start = scanner.pos
          break unless scanner.skip_until(ERB_CLOSE)
          next if comment

          code = source.byteslice(start, scanner.pos - start - 2)
          fragments << code.sub(ERB_LEADING_MARK, '').sub(ERB_TRAILING_MARK, '')
        end
        fragments
      end

      # @param source [String]
      # @return [Array<String>]
      def haml(source)
        state = { fragments: [], block: nil, pending: nil }
        source.each_line { |line| haml_line(line.chomp, state) }
        state[:fragments] << state[:pending] if state[:pending]
        state[:fragments]
      end

      # One line of HAML: a continuation of the script above it, the body of
      # an opaque block (a silent comment or a filter), or a line of its own.
      def haml_line(text, state)
        stripped = text.strip
        return haml_continue(stripped, state) if state[:pending]

        indent = text[HAML_INDENT].length
        block = state[:block]
        if block && (stripped.empty? || indent > block[:indent])
          state[:fragments] << stripped if block[:ruby] && !stripped.empty?
          return
        end

        state[:block] = haml_opaque_block(stripped, indent)
        haml_script_line(stripped, state) unless state[:block]
      end

      def haml_continue(stripped, state)
        state[:pending] << "\n" << stripped
        return if stripped.end_with?(',')

        state[:fragments] << state[:pending]
        state[:pending] = nil
      end

      # @return [Hash, nil] `{ indent:, ruby: }` when the line opens a block
      #   whose body is not HAML
      def haml_opaque_block(stripped, indent)
        return { indent: indent, ruby: false } if stripped.start_with?('-#')

        filter = stripped[HAML_FILTER, 1]
        { indent: indent, ruby: filter == 'ruby' } if filter
      end

      def haml_script_line(stripped, state)
        code = haml_script(stripped)
        return unless code

        code.rstrip.end_with?(',') ? state[:pending] = code.dup : state[:fragments] << code
      end

      # @return [String, nil] the Ruby after a script mark, with any tag and
      #   its attributes skipped; nil for a line that is plain text
      def haml_script(stripped)
        scanner = StringScanner.new(stripped)
        if scanner.skip(HAML_TAG_HEAD)
          skip_haml_attributes(scanner)
          scanner.skip(HAML_TAG_MARKS)
        end
        scanner.skip(HAML_SCRIPT) ? scanner.rest : nil
      end

      # Attribute groups nest and may hold any Ruby, so they are skipped by
      # bracket depth. A group left open on the line consumes the rest of it.
      def skip_haml_attributes(scanner)
        while HAML_OPENERS.include?(scanner.peek(1)) && !scanner.eos?
          depth = 0
          until scanner.eos?
            char = scanner.getch
            depth += 1 if HAML_OPENERS.include?(char)
            depth -= 1 if HAML_CLOSERS.include?(char)
            break if depth.zero?
          end
        end
      end
    end
  end
end
