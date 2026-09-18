# frozen_string_literal: true

require 'set'

module Woods
  module MCP
    # Accumulates a bounded search prefix and evidence about its completeness.
    # A full page is not evidence of truncation: only an additional distinct
    # typed match establishes that more results exist. Budget/timeout cutoffs
    # leave both the total and the existence of another match unknown.
    class SearchResults
      NARROWING_HINT = 'Narrow types, literal exact_prefix/exact_suffix filters, or the requested deep fields.'

      def self.unavailable
        { status: 'unknown', reason: 'unreadable_or_corrupt_source', has_more: nil,
          total_matches: nil, matched_lower_bound: nil }
      end

      def initialize(limit:)
        @limit = limit
        @matches = []
        @seen = Set.new
        @reason = nil
      end

      # Admit at most one lookahead match beyond the returned page.
      # @return [self]
      def add(identifier:, type:, match_field:)
        return self if result_limit_reached?
        return self unless @seen.add?([type, identifier])

        @matches << { identifier: identifier, type: type, match_field: match_field }
        @reason = 'result_limit' if @matches.size > @limit
        self
      end

      def result_limit_reached?
        @reason == 'result_limit'
      end

      # Stop because the remaining search domain could not be examined.
      def stop(reason)
        @reason = reason
      end

      # The caller must establish exhaustion rather than infer it from page size.
      def finish
        @reason ||= 'exhausted'
        self
      end

      # @param note [String, nil] existing advisory/timeout guidance
      # @return [Hash] returned rows plus additive completeness metadata
      def response(note: nil)
        raise ArgumentError, 'Search has not finished' unless @reason

        complete = @reason == 'exhausted'
        result = {
          results: @matches.first(@limit),
          completeness: {
            status: complete ? 'complete' : 'partial', reason: @reason,
            has_more: complete ? false : (true if result_limit_reached?),
            total_matches: complete ? @matches.size : nil,
            matched_lower_bound: @matches.size
          }
        }
        result[:partial] = true unless complete
        result[:hint] = NARROWING_HINT unless complete
        result[:note] = note unless note.nil? || note.empty?
        result
      end
    end
  end
end
