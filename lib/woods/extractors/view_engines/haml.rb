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
      # `:css`, ...) and `-#` silent-comment bodies are not Ruby, so partial,
      # helper, and route-helper scans skip them. The instance-variable scan
      # reads the raw source, as {Erb} does.
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

        # The source with non-Ruby filter bodies and silent-comment bodies
        # removed. A block is the opening line plus every following line
        # that is blank or indented deeper than it.
        #
        # @param source [String]
        # @return [String]
        def scannable_source(source)
          block_indent = nil
          source.each_line.reject do |line|
            indent = line[/\A[ \t]*/].length
            next true if block_indent && (line.strip.empty? || indent > block_indent)

            block_indent = opaque_block_start?(line) ? indent : nil
            !block_indent.nil?
          end.join
        end

        # @param line [String]
        # @return [Boolean]
        def opaque_block_start?(line)
          return true if line.match?(SILENT_COMMENT)

          filter = line[FILTER_LINE, 1]
          !filter.nil? && !RUBY_FILTERS.include?(filter)
        end
      end
    end
  end
end
