# frozen_string_literal: true

module CodebaseIndex
  module Feedback
    # Detects patterns in retrieval feedback that suggest coverage gaps.
    #
    # Analyzes ratings and gap reports to find:
    # - Repeated low-score queries with common keywords
    # - Frequently reported missing units
    #
    # @example
    #   detector = GapDetector.new(feedback_store: store)
    #   issues = detector.detect
    #   issues.each { |i| puts "#{i[:type]}: #{i[:description]}" }
    #
    class GapDetector
      LOW_SCORE_THRESHOLD = 2
      MIN_PATTERN_COUNT = 2
      MIN_GAP_COUNT = 2

      # @param feedback_store [Feedback::Store]
      def initialize(feedback_store:)
        @feedback_store = feedback_store
      end

      # Detect coverage gaps from accumulated feedback.
      #
      # @return [Array<Hash>] List of detected issues with :type, :description, and details
      def detect
        issues = []
        issues.concat(detect_low_score_patterns)
        issues.concat(detect_frequently_missing)
        issues
      end

      private

      # Find keyword patterns in low-scoring queries.
      #
      # @return [Array<Hash>]
      def detect_low_score_patterns
        low_ratings = @feedback_store.ratings.select { |r| r['score'] <= LOW_SCORE_THRESHOLD }
        return [] if low_ratings.size < MIN_PATTERN_COUNT

        keyword_counts = count_keywords(low_ratings)
        keyword_counts.select { |_, count| count >= MIN_PATTERN_COUNT }.map do |keyword, count|
          {
            type: :repeated_low_scores,
            pattern: keyword,
            count: count,
            description: "#{count} low-score queries mention '#{keyword}'"
          }
        end
      end

      # Count keyword occurrences across low-scoring query texts.
      #
      # @param ratings [Array<Hash>] Low-score rating entries
      # @return [Hash<String, Integer>] Keyword => occurrence count
      def count_keywords(ratings)
        counts = Hash.new(0)
        ratings.each do |rating|
          words = rating['query'].to_s.downcase.split(/\W+/).reject { |w| w.length < 3 }
          words.each { |w| counts[w] += 1 }
        end
        counts
      end

      # Find units that are frequently reported as missing.
      #
      # @return [Array<Hash>]
      def detect_frequently_missing
        unit_counts = Hash.new(0)
        @feedback_store.gaps.each do |gap|
          unit_counts[gap['missing_unit']] += 1
        end

        unit_counts.select { |_, count| count >= MIN_GAP_COUNT }.map do |unit, count|
          {
            type: :frequently_missing,
            unit: unit,
            count: count,
            description: "#{unit} reported missing #{count} times"
          }
        end
      end
    end
  end
end
