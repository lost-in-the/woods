# frozen_string_literal: true

require 'set'
require_relative 'erb'

module Woods
  module Extractors
    module ViewEngines
      # HAML implementation of the {Base} template-engine contract.
      #
      # Like {Erb} it regex-scans the whole template source rather than
      # compiling it, so it needs no HAML gem at extraction time. Whole-source
      # scanning also covers HAML's multi-line Ruby: a line ending in a comma
      # continues on the next line, and the patterns below follow that rule.
      #
      # Filter bodies other than `:ruby` and `:erb` (`:plain`, `:javascript`,
      # `:css`, ...) are not Ruby, so partial, helper, and route-helper scans
      # skip their text but read each `#{...}` interpolation, which HAML
      # evaluates. `-#` silent-comment bodies are skipped entirely. The
      # instance-variable scan reads the raw source, as {Erb} does.
      #
      # Inherits the helper vocabulary and instance-variable scan from {Erb};
      # partial and form-action scans are HAML-specific.
      class Haml < Erb
        # File extensions this engine handles.
        EXTENSIONS = %w[.html.haml .haml].freeze

        # Stable engine identifier — see Base#name.
        ENGINE_NAME = :haml

        # Every quantifier that could meet another one over the same
        # characters is possessive, so scans stay linear on uncontrolled
        # template text.

        # `render 'path'` and `render('path', ...)`.
        POSITIONAL_PARTIAL = /\brender\b\s*+(?:\(\s*+)?['"]([^'"]+)['"]/

        # `render :name` shorthand.
        SYMBOL_PARTIAL = /\brender\b\s*+(?:\(\s*+)?:(\w+)/

        # The start of a render call within a statement.
        RENDER_CALL = /\brender\b/

        # A `partial:` (or `:partial =>`) option, read from the arguments
        # that follow a render call, e.g. after `collection:`.
        PARTIAL_OPTION = /(?:\bpartial:|:partial\s*+=>)\s*+['"]([^'"]+)['"]/

        # A form_with / form_for call, or a route helper (captured).
        FORM_OR_ROUTE_HELPER = /\bform_(?:with|for)\b|\b(\w+)_(path|url)\b/

        # A filter line such as `:javascript`; the capture is the filter name.
        FILTER_LINE = /\A[ \t]*:(\w+)[ \t]*$/

        # A `-#` silent comment line.
        SILENT_COMMENT = /\A[ \t]*-#/

        # Filters whose body is Ruby (or ERB) and stays scannable.
        RUBY_FILTERS = %w[ruby erb].freeze

        # A script marker: `-` (not the `-#` comment), `~`, `=`, `!=`, `&=`.
        # `==` and its variants are interpolated text, not Ruby.
        SCRIPT = /\A(?:-(?!#)|~|[!&]?=(?!=))/

        # The `%tag.class#id` head of an element line. A `#` or `.` needs a
        # name after it, so a line that opens with `\#{` is not a tag.
        TAG_HEAD = /\A(?:%[\w:-]++|[.#][\w-]++)++/

        # An attribute name and its `=` inside HTML-style `(...)` attributes.
        HTML_ATTRIBUTE_NAME = /[\w:-]++=/

        # Whitespace-removal markers between a tag's attributes and its content.
        TAG_TRIM = /\A[<>]++/

        # The bracket that closes each kind of attribute list.
        ATTRIBUTE_CLOSERS = { '{' => '}', '(' => ')', '[' => ']' }.freeze

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
          code = scannable_source(source)
          partials = Set.new
          code.scan(POSITIONAL_PARTIAL) { |(name)| partials << name }
          code.scan(SYMBOL_PARTIAL) do |(name)|
            partials << name unless RESERVED_RENDER_OPTIONS.include?(name)
          end
          statements(code).each do |statement|
            start = statement =~ RENDER_CALL
            statement[start..].scan(PARTIAL_OPTION) { |(name)| partials << name } if start
          end
          partials.to_a
        end

        # @see Base#scan_helpers
        def scan_helpers(source)
          super(scannable_source(source))
        end

        # @see Base#scan_method_calls
        def scan_method_calls(source, names)
          HelperCallScan.method_calls(ruby_code(source), names)
        end

        # @see Base#scan_navigation_candidates
        def scan_navigation_candidates(source)
          code = scannable_source(source)
          link_to_candidates = code.scan(ROUTE_HELPER_PATTERN).map do |route_name, suffix|
            { helper: "#{route_name}_#{suffix}", via: :link_to }
          end
          link_to_candidates + form_action_candidates(code)
        end

        private

        # @see Erb#partial_extension
        def partial_extension
          '.html.haml'
        end

        # The first route helper after each form_with / form_for call in the
        # same statement, found in one token pass.
        #
        # @param code [String]
        # @return [Array<Hash>]
        def form_action_candidates(code)
          statements(code).flat_map do |statement|
            form_open = false
            statement.scan(FORM_OR_ROUTE_HELPER).filter_map do |route_name, suffix|
              if route_name.nil?
                form_open = true
                next
              end
              next unless form_open

              form_open = false
              { helper: "#{route_name}_#{suffix}", via: :form_action }
            end
          end
        end

        # The source with silent-comment bodies removed and non-Ruby filter
        # bodies replaced by their interpolations. A block is the opening
        # line plus every following line that is blank or indented deeper
        # than it.
        #
        # @param source [String]
        # @return [String]
        def scannable_source(source)
          block = nil
          source.each_line.with_object(+'') do |line, code|
            indent = line[/\A[ \t]*/].length
            if block && (line.strip.empty? || indent > block[:indent])
              code << interpolations(line) if block[:filter]
              next
            end

            block = opaque_block(line, indent)
            code << line unless block
          end
        end

        # Only the Ruby in a template: script lines, attribute lists, the
        # interpolations of text, and `:ruby` / `:erb` filter bodies. Plain
        # text, tag names, and silent comments are dropped, so a word of
        # copy that matches a method name is never read as a call.
        #
        # @param source [String]
        # @return [String]
        def ruby_code(source)
          block = nil
          open = { continued: false, bracket: nil, depth: 0 }
          source.each_line.with_object(+'') do |line, code|
            indent = line[/\A[ \t]*/].length
            if block && (line.strip.empty? || indent > block[:indent])
              code << block_body_ruby(line, block[:body])
              next
            end

            block = body_block(line, indent)
            code << line_ruby(line.strip, open) << "\n" unless block
          end
        end

        # @param line [String]
        # @param indent [Integer]
        # @return [Hash, nil] `{ indent:, body: }` when the line opens a
        #   silent comment (`:skip`) or a filter (`:ruby`, `:erb`, `:text`)
        def body_block(line, indent)
          return { indent: indent, body: :skip } if line.match?(SILENT_COMMENT)

          filter = line[FILTER_LINE, 1]
          { indent: indent, body: { 'ruby' => :ruby, 'erb' => :erb }.fetch(filter, :text) } if filter
        end

        # @param line [String]
        # @param body [Symbol]
        # @return [String]
        def block_body_ruby(line, body)
          case body
          when :ruby then line
          when :erb then ruby_regions(line).first
          when :text then interpolations(line)
          else ''
          end
        end

        # The Ruby on one line. `open` carries what a previous line left
        # unfinished: a script ending in a comma, or an attribute list whose
        # closing bracket has not come yet.
        #
        # @param text [String] the line, stripped
        # @param open [Hash]
        # @return [String]
        def line_ruby(text, open)
          return continued_ruby(text, open) if open[:continued] || open[:bracket]

          if (script = text.match(SCRIPT))
            script_ruby(script.post_match, open)
          elsif (head = text[TAG_HEAD])
            tag_ruby(text.byteslice(head.bytesize..), open)
          else
            interpolations(text)
          end
        end

        def continued_ruby(text, open)
          open[:depth] = bracket_depth(text, open[:bracket], open[:depth]) if open[:bracket]
          open[:bracket] = nil unless open[:depth].positive?
          open[:continued] = open[:bracket].nil? && text.end_with?(',')
          text
        end

        def script_ruby(ruby, open)
          open[:continued] = ruby.rstrip.end_with?(',')
          ruby
        end

        # The Ruby after a tag head: each attribute list, then a script if
        # the content starts with a script marker, else the text's
        # interpolations.
        def tag_ruby(rest, open)
          code = +''
          while (closer = ATTRIBUTE_CLOSERS[rest[0]])
            depth = bracket_depth(rest, rest[0], 0)
            if depth.positive?
              open.merge!(bracket: rest[0], depth: depth)
              return code << attribute_ruby(rest)
            end
            stop = closing_byte(rest, rest[0], closer)
            code << attribute_ruby(rest.byteslice(0..stop)) << "\n"
            rest = rest.byteslice((stop + 1)..)
          end
          rest = rest.sub(TAG_TRIM, '')
          script = rest.match(SCRIPT)
          code << (script ? script_ruby(script.post_match, open) : interpolations(rest))
        end

        # HTML-style attributes are `name=ruby` pairs: the names are not
        # Ruby, and read as assignments they would shadow a helper.
        def attribute_ruby(list)
          list.start_with?('(') ? list.gsub(HTML_ATTRIBUTE_NAME, ' ') : list
        end

        # Net count of unclosed `bracket`s after `text`, starting at `depth`.
        def bracket_depth(text, bracket, depth)
          opener = bracket.ord
          closer = ATTRIBUTE_CLOSERS.fetch(bracket).ord
          text.each_byte do |byte|
            depth += 1 if byte == opener
            depth -= 1 if byte == closer && depth.positive?
          end
          depth
        end

        # Byte offset of the bracket that closes the one at offset 0.
        def closing_byte(text, bracket, closer)
          opener = bracket.ord
          closer = closer.ord
          depth = 0
          text.each_byte.with_index do |byte, offset|
            depth += 1 if byte == opener
            next unless byte == closer

            depth -= 1
            return offset if depth.zero?
          end
          text.bytesize - 1
        end

        # @param line [String]
        # @param indent [Integer]
        # @return [Hash, nil] `{ indent:, filter: }` when the line opens a
        #   block whose body is not Ruby
        def opaque_block(line, indent)
          return { indent: indent, filter: false } if line.match?(SILENT_COMMENT)

          filter = line[FILTER_LINE, 1]
          { indent: indent, filter: true } if filter && !RUBY_FILTERS.include?(filter)
        end

        # The Ruby inside each `#{...}` of a line of filter text, one per
        # line. Braces nest, so `#{f { 1 }}` yields `f { 1 }`; an
        # interpolation left open on the line yields nothing. Offsets are
        # bytes, so a line of multibyte text is still read in one pass.
        #
        # @param text [String]
        # @return [String]
        def interpolations(text)
          bytes = text.b
          code = +''
          start = 0
          while (open = bytes.index('#{', start))
            close = matching_brace(bytes, open + 2)
            break unless close

            code << bytes.byteslice((open + 2)...close).force_encoding(text.encoding) << "\n"
            start = close + 1
          end
          code
        end

        # @param bytes [String] Binary copy of the text
        # @param from [Integer] Byte offset just after an opening brace
        # @return [Integer, nil] Byte offset of the brace that closes it
        def matching_brace(bytes, from)
          depth = 1
          (from...bytes.bytesize).each do |offset|
            case bytes.getbyte(offset)
            when 123 then depth += 1
            when 125
              depth -= 1
              return offset if depth.zero?
            end
          end
          nil
        end
      end
    end
  end
end
