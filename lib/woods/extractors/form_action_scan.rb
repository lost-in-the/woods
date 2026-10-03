# frozen_string_literal: true

module Woods
  module Extractors
    # Finds the route helper a form_with / form_for call submits to, in one
    # linear pass over uncontrolled source.
    #
    # The result equals scanning
    # `form_(with|for)\b<span>*?(\w+)_(path|url)`, where the lazy span may
    # not cross a stop (ERB passes `%`, Ruby-aware scanners pass `%>`, `do`,
    # and `end`). That regex backtracks polynomially, because the span and
    # the unanchored `\w+` both cover word characters. The rules it applied
    # are kept:
    #
    # - the helper is the first word, after the call and before the next
    #   stop, that holds `_path` or `_url` after its first character;
    # - within that word the last such suffix wins, as greedy `\w+` chooses;
    # - a helper serves one form call, and scanning resumes after its suffix,
    #   so a form call inside a consumed word is skipped.
    module FormActionScan
      # A form_with / form_for call. No leading `\b`: `my_form_with` counts.
      FORM_CALL = /form_(?:with|for)\b/

      # A run of word characters; a route helper is read from one run.
      WORD_RUN = /\w+/

      # A route-helper suffix inside a word run.
      ROUTE_SUFFIX = /_(?:path|url)/

      module_function

      # @param source [String]
      # @param stop [Regexp] Where a form call's argument span ends
      # @return [Array<Array(String, String)>] `[route_name, suffix]` per
      #   form call that reaches a helper, in source order
      def route_helpers(source, stop:)
        return [] unless source.match?(FORM_CALL)

        helpers = helper_words(source)
        stops = positions(source, stop).map(&:first)
        found = []
        resume = helper_index = stop_index = 0
        positions(source, FORM_CALL).each do |call_start, call_end|
          next if call_start < resume

          helper_index += 1 while helper_index < helpers.size && helpers[helper_index][0] < call_end
          stop_index += 1 while stop_index < stops.size && stops[stop_index] < call_end
          start, finish, route_name, suffix = helpers[helper_index]
          next unless start && (stop_index == stops.size || start < stops[stop_index])

          found << [route_name, suffix]
          resume = finish
        end
        found
      end

      # Every word run holding a route-helper suffix after its first
      # character, as `[start, end_of_suffix, route_name, suffix]`.
      #
      # @param source [String]
      # @return [Array<Array>]
      def helper_words(source)
        positions(source, WORD_RUN).filter_map do |start, finish|
          word = source[start...finish]
          at = word.rindex(ROUTE_SUFFIX)
          next unless at&.positive?

          suffix = word[at + 1, 4] == 'path' ? 'path' : 'url'
          [start, start + at + 1 + suffix.length, word[0...at], suffix]
        end
      end

      # Character offsets `[start, end]` of every match of a pattern.
      #
      # @param source [String]
      # @param pattern [Regexp]
      # @return [Array<Array(Integer, Integer)>]
      def positions(source, pattern)
        found = []
        source.scan(pattern) do
          match = Regexp.last_match
          found << [match.begin(0), match.end(0)]
        end
        found
      end
    end
  end
end
