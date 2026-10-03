# frozen_string_literal: true

require 'set'
require_relative 'base'

module Woods
  module Extractors
    module ViewEngines
      # ERB implementation of the {Base} template-engine contract. Owns
      # the ERB-specific parsing surface that {ViewTemplateExtractor}
      # delegates to — extension list, partial filename convention, and
      # the three scan operations (partials, instance variables, helper
      # calls).
      class Erb < Base
        # File extensions this engine handles.
        EXTENSIONS = %w[.html.erb .erb].freeze

        # Stable engine identifier — see Base#name.
        ENGINE_NAME = :erb

        # Matches named route helpers (e.g. `posts_path`, `user_url`) in
        # template source. Same shape as
        # {SharedDependencyScanner::ROUTE_HELPER_PATTERN}, but this engine
        # has no dependency on that module, so it keeps its own copy.
        ROUTE_HELPER_PATTERN = /\b(\w+)_(path|url)\b/

        # A form_with / form_for call. Its action is the first route helper
        # after it and before the next `%`, the ERB tag terminator. See
        # {#form_action_candidates}, which finds it in one linear pass.
        FORM_CALL = /form_(?:with|for)\b/

        # A run of word characters; a route helper is read from one run.
        WORD_RUN = /\w+/

        # A route-helper suffix inside a word run.
        ROUTE_SUFFIX = /_(?:path|url)/

        # Common Rails view helper methods to detect in template source.
        COMMON_HELPERS = %w[
          link_to
          button_to
          form_for
          form_with
          form_tag
          image_tag
          stylesheet_link_tag
          javascript_include_tag
          content_for
          yield
          render
          redirect_to
          truncate
          pluralize
          number_to_currency
          number_to_percentage
          number_with_delimiter
          time_ago_in_words
          distance_of_time_in_words
          simple_format
          sanitize
          raw
          safe_join
          content_tag
          tag
          mail_to
          url_for
          asset_path
          asset_url
        ].freeze

        # @see Base#name
        def name
          ENGINE_NAME
        end

        # @see Base#extensions
        def extensions
          EXTENSIONS
        end

        # Render option keys that are never themselves a partial name. The
        # bare `render :foo` shorthand pattern below cannot tell `render
        # :partial => 'shared/header'` (the pre-Ruby-3.0 hash-rocket form of
        # the `partial:` option) from an actual `render :partial_name` call,
        # so it must exclude these explicitly rather than record the option
        # key as a partial.
        RESERVED_RENDER_OPTIONS = %w[partial template layout].freeze

        # Matches:
        # - `render partial: 'foo/bar'`
        # - `render :partial => 'foo/bar'` (hash-rocket form)
        # - `render 'foo/bar'`
        # - `render :foo`
        #
        # @see Base#scan_partials
        def scan_partials(source)
          partials = Set.new

          source.scan(/render\s+partial:\s*['"]([^'"]+)['"]/).each do |match|
            partials << match[0]
          end

          source.scan(/render\s+:partial\s*=>\s*['"]([^'"]+)['"]/).each do |match|
            partials << match[0]
          end

          source.scan(/render\s+['"]([^'"]+)['"]/).each do |match|
            partials << match[0]
          end

          source.scan(/render\s+:(\w+)/).each do |match|
            partials << match[0] unless RESERVED_RENDER_OPTIONS.include?(match[0])
          end

          partials.to_a
        end

        # @see Base#scan_instance_variables
        def scan_instance_variables(source)
          source.scan(/@[a-zA-Z_]\w*/).uniq.sort
        end

        # @see Base#scan_helpers
        def scan_helpers(source)
          found = Set.new
          COMMON_HELPERS.each do |helper|
            found << helper if source.match?(/\b#{Regexp.escape(helper)}\b/)
          end
          found.to_a.sort
        end

        # Given `render 'comments/comment'` from a template at
        # `posts/show.html.erb`, resolves to `comments/_comment.html.erb`.
        #
        # @see Base#resolve_partial_identifier
        def resolve_partial_identifier(partial_name, current_identifier)
          if partial_name.include?('/')
            dir = File.dirname(partial_name)
            base = File.basename(partial_name)
            "#{dir}/_#{base}#{partial_extension}"
          else
            dir = File.dirname(current_identifier)
            if dir == '.'
              "_#{partial_name}#{partial_extension}"
            else
              "#{dir}/_#{partial_name}#{partial_extension}"
            end
          end
        end

        # @see Base#scan_navigation_candidates
        def scan_navigation_candidates(source)
          link_to_candidates = source.scan(ROUTE_HELPER_PATTERN).map do |route_name, suffix|
            { helper: "#{route_name}_#{suffix}", via: :link_to }
          end
          link_to_candidates + form_action_candidates(source)
        end

        private

        # Extension {#resolve_partial_identifier} appends to a partial name.
        #
        # @return [String]
        def partial_extension
          '.html.erb'
        end

        # Form-action candidates, one per form call that reaches a route
        # helper before the next `%`. A helper serves one form call, and a
        # form call inside a consumed helper word is skipped. Equivalent to
        # scanning `form_(with|for)\b[^%]*?(\w+)_(path|url)`, without that
        # pattern's polynomial backtracking.
        #
        # @param source [String]
        # @return [Array<Hash>]
        def form_action_candidates(source)
          return [] unless source.match?(FORM_CALL)

          helpers = route_helper_words(source)
          percents = positions(source, /%/)
          candidates = []
          resume = helper_index = percent_index = 0
          positions(source, FORM_CALL, with_end: true).each do |call_start, call_end|
            next if call_start < resume

            helper_index += 1 while helper_index < helpers.size && helpers[helper_index][0] < call_end
            percent_index += 1 while percent_index < percents.size && percents[percent_index] < call_end
            start, finish, helper = helpers[helper_index]
            next unless start && (percent_index == percents.size || start < percents[percent_index])

            candidates << { helper: helper, via: :form_action }
            resume = finish
          end
          candidates
        end

        # Every word run that holds a route-helper suffix after its first
        # character, as `[start, end_of_suffix, helper]`. The last suffix in
        # the run wins, as a greedy `(\w+)_(path|url)` would choose.
        #
        # @param source [String]
        # @return [Array<Array>]
        def route_helper_words(source)
          positions(source, WORD_RUN, with_end: true).filter_map do |start, finish|
            word = source[start...finish]
            at = word.rindex(ROUTE_SUFFIX)
            next unless at&.positive?

            suffix = word[at + 1, 4] == 'path' ? 'path' : 'url'
            [start, start + at + 1 + suffix.length, "#{word[0...at]}_#{suffix}"]
          end
        end

        # Character offsets of every match of a pattern.
        #
        # @param source [String]
        # @param pattern [Regexp]
        # @param with_end [Boolean] Return `[start, end]` pairs
        # @return [Array]
        def positions(source, pattern, with_end: false)
          found = []
          source.scan(pattern) do
            match = Regexp.last_match
            found << (with_end ? [match.begin(0), match.end(0)] : match.begin(0))
          end
          found
        end

        # Source lines joined into Ruby statements: a line ending in a comma
        # continues on the next line. One linear pass, so callers can scan a
        # call's arguments with anchored patterns instead of a lazy span.
        #
        # @param source [String]
        # @return [Array<String>]
        def statements(source)
          joined = []
          continued = false
          source.each_line do |line|
            continued ? joined.last << line : joined << line.dup
            continued = line.rstrip.end_with?(',')
          end
          joined
        end
      end
    end
  end
end
