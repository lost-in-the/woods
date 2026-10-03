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

        # Arguments of one Ruby call: any character up to the end of the
        # line, crossing a line break only after a trailing comma.
        CALL_ARGUMENTS = '(?:[^\n]|,[ \t]*\n)*?'

        # `render 'path'` and `render('path', ...)`.
        POSITIONAL_PARTIAL = /\brender\b\s*\(?\s*['"]([^'"]+)['"]/

        # A `partial:` (or `:partial =>`) option anywhere in a render call's
        # arguments, e.g. after `collection:`.
        PARTIAL_OPTION = /\brender\b#{CALL_ARGUMENTS}(?:\bpartial:|:partial\s*=>)\s*['"]([^'"]+)['"]/

        # `render :name` shorthand.
        SYMBOL_PARTIAL = /\brender\b\s*\(?\s*:(\w+)/

        # form_with / form_for whose arguments name a route helper.
        FORM_ACTION_HELPER = /\bform_(?:with|for)\b#{CALL_ARGUMENTS}\b(\w+)_(path|url)\b/

        # A filter line such as `:javascript`; the capture is the filter name.
        FILTER_LINE = /\A[ \t]*:(\w+)[ \t]*$/

        # A `-#` silent comment line.
        SILENT_COMMENT = /\A[ \t]*-#/

        # Filters whose body is Ruby (or ERB) and stays scannable.
        RUBY_FILTERS = %w[ruby erb].freeze

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
          [POSITIONAL_PARTIAL, PARTIAL_OPTION].each do |pattern|
            code.scan(pattern) { |(name)| partials << name }
          end
          code.scan(SYMBOL_PARTIAL) do |(name)|
            partials << name unless RESERVED_RENDER_OPTIONS.include?(name)
          end
          partials.to_a
        end

        # @see Base#scan_helpers
        def scan_helpers(source)
          super(scannable_source(source))
        end

        # @see Base#scan_navigation_candidates
        def scan_navigation_candidates(source)
          code = scannable_source(source)
          link_to_candidates = code.scan(ROUTE_HELPER_PATTERN).map do |route_name, suffix|
            { helper: "#{route_name}_#{suffix}", via: :link_to }
          end
          form_candidates = code.scan(FORM_ACTION_HELPER).map do |route_name, suffix|
            { helper: "#{route_name}_#{suffix}", via: :form_action }
          end
          link_to_candidates + form_candidates
        end

        private

        # @see Erb#partial_extension
        def partial_extension
          '.html.haml'
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
        # interpolation left open on the line yields nothing.
        #
        # @param text [String]
        # @return [String]
        def interpolations(text)
          code = +''
          start = 0
          while (open = text.index('#{', start))
            close = matching_brace(text, open + 2)
            break unless close

            code << text[(open + 2)...close] << "\n"
            start = close + 1
          end
          code
        end

        # @param text [String]
        # @param from [Integer] Index just after an opening brace
        # @return [Integer, nil] Index of the brace that closes it
        def matching_brace(text, from)
          depth = 1
          (from...text.length).each do |index|
            case text[index]
            when '{' then depth += 1
            when '}'
              depth -= 1
              return index if depth.zero?
            end
          end
          nil
        end
      end
    end
  end
end
