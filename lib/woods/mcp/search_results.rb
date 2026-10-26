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

      # Same completeness keys as {#response}, for a bounded sync report.
      # Adds +failed+ (nothing landed), which search never emits. +has_more+ is true when listed errors are fewer
      # than the total, and the total sits inside the hash like +total_matches+.
      #
      # @param error_count [Integer] uncapped number of errors
      # @param listed [Integer] number of errors returned to the caller
      # @param landed [Integer] pages written or already up to date
      # @return [Hash] completeness evidence
      def self.sync_outcome(error_count:, listed:, landed:)
        reason = if error_count.zero? then 'exhausted'
                 elsif landed.positive? then 'page_errors'
                 else 'nothing_synced'
                 end
        status = { 'exhausted' => 'complete', 'page_errors' => 'partial', 'nothing_synced' => 'failed' }.fetch(reason)
        { status: status, reason: reason, has_more: error_count > listed, total_errors: error_count }
      end

      # Same completeness keys as {#response}, for a row-capped result set that
      # fetched one lookahead row. +has_more+ is true only when that extra row arrived.
      #
      # @param returned [Integer] rows handed to the caller
      # @param has_more [Boolean] whether a row beyond the cap exists
      # @return [Hash] completeness evidence
      def self.row_limit_outcome(returned:, has_more:)
        { status: has_more ? 'partial' : 'complete', reason: has_more ? 'result_limit' : 'exhausted',
          has_more: has_more, total_matches: has_more ? nil : returned, matched_lower_bound: returned }
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
        unless complete
          result[:hint] = if @reason == 'unreadable_or_corrupt_source'
                            'Run woods:validate and repair or republish unreadable unit artifacts.'
                          else
                            NARROWING_HINT
                          end
        end
        result[:note] = note unless note.nil? || note.empty?
        result
      end
    end
  end
end
