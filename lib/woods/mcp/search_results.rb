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

      # Guidance for a deep search its scan budget stopped: how much it read,
      # and, when nothing matched, that the empty answer proves nothing about
      # the unread units. A byte or time stop names no unit count: the
      # candidate count is this query's types only, and a server-wide
      # WOODS_SEARCH_MAX_SCAN set from it would cap every later, broader
      # search and drop both default caps.
      #
      # @param scanned [Integer] candidate unit bodies read
      # @param candidates [Integer] candidate unit bodies queued
      # @param matched [Integer] results returned
      # @param limit_hit [String] "units", "bytes" or "seconds"
      # @param knob [String] what set the unit cap: "max_scan" or "WOODS_SEARCH_MAX_SCAN"
      # @return [String]
      def self.scan_budget_hint(scanned:, candidates:, matched:, limit_hit:, knob: 'WOODS_SEARCH_MAX_SCAN')
        unread = candidates - scanned
        cap = { 'units' => 'unit-count cap', 'bytes' => 'size cap', 'seconds' => 'time cap' }.fetch(limit_hit)
        read = "Deep-field scan read #{scanned} of #{candidates} candidate units before its #{cap} stopped it; "
        verdict = if matched.zero?
                    "the other #{unread} were never searched, so 0 results is NOT evidence of absence. "
                  else
                    "matches in the #{unread} unread units are unknown. "
                  end
        "#{read}#{verdict}#{scan_budget_action(limit_hit, scanned, knob)}"
      end

      def self.scan_budget_action(limit_hit, scanned, knob)
        narrow = 'narrow types, exact_prefix/exact_suffix, or fields'
        return "Raise #{knob} above #{scanned}, or #{narrow}, and search again." if limit_hit == 'units'

        "Search again (a warm cache is usually much faster), or #{narrow}."
      end
      private_class_method :scan_budget_action

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

      # Completeness for an offset/limit page over a fully known list: the total
      # is exact, so only the unreturned tail decides +has_more+.
      #
      # @param total [Integer] size of the whole list
      # @param offset [Integer] items skipped
      # @param returned [Integer] items on this page
      # @return [Hash] completeness evidence, same keys as {#response}
      def self.page(total:, offset:, returned:)
        more = offset + returned < total
        { status: more ? 'partial' : 'complete', reason: more ? 'result_limit' : 'exhausted',
          has_more: more, total_matches: total, matched_lower_bound: total }
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
        @overflowed = false
      end

      # Admit at most one lookahead match beyond the returned page. Matches are
      # still admitted after {#stop}: a caller that skips an unreadable unit
      # keeps searching the rest of the domain.
      #
      # @param identifier [String]
      # @param type [String]
      # @param match_field [String]
      # @return [self]
      def add(identifier:, type:, match_field:)
        return self if result_limit_reached?
        return self unless @seen.add?([type, identifier])

        @matches << { identifier: identifier, type: type, match_field: match_field }
        if @matches.size > @limit
          @overflowed = true
          # A reason {#stop} recorded (part of the domain was never examined)
          # is stronger than a full page and must not be replaced by it; the
          # lookahead still shows in +has_more+.
          @reason ||= 'result_limit'
        end
        self
      end

      # @return [Boolean] true once a match beyond the page was admitted
      def result_limit_reached?
        @overflowed
      end

      # Stop because the remaining search domain could not be examined.
      #
      # @param reason [String]
      # @return [String]
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
