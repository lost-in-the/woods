# frozen_string_literal: true

module CodebaseIndex
  module Evaluation
    # Runs simple baseline strategies for comparison against the full
    # retrieval pipeline.
    #
    # Provides three baseline strategies:
    # - `:grep` — substring match on unit identifiers
    # - `:random` — random selection from available units
    # - `:file_level` — returns identifiers matching file paths
    #
    # @example
    #   runner = BaselineRunner.new(metadata_store: store)
    #   results = runner.run("User model", strategy: :grep, limit: 10)
    #   results  # => ["User", "UserProfile", "UserSerializer"]
    #
    class BaselineRunner
      VALID_STRATEGIES = %i[grep random file_level].freeze

      # @param metadata_store [Object] Store that responds to #all_identifiers and #find_by_type
      def initialize(metadata_store:)
        @metadata_store = metadata_store
      end

      # Run a baseline strategy for a query.
      #
      # @param query [String] Natural language query
      # @param strategy [Symbol] Baseline strategy (:grep, :random, :file_level)
      # @param limit [Integer] Maximum number of results
      # @return [Array<String>] Unit identifiers
      # @raise [ArgumentError] if the strategy is invalid
      def run(query, strategy:, limit: 10)
        unless VALID_STRATEGIES.include?(strategy)
          raise ArgumentError, "Invalid strategy: #{strategy}. Must be one of #{VALID_STRATEGIES.join(', ')}"
        end

        send(:"run_#{strategy}", query, limit)
      end

      private

      # Grep strategy: substring match on unit identifiers.
      #
      # Extracts words from the query and matches identifiers that contain
      # any query word (case-insensitive).
      #
      # @param query [String] Query string
      # @param limit [Integer] Max results
      # @return [Array<String>]
      def run_grep(query, limit)
        all_ids = @metadata_store.all_identifiers
        keywords = extract_keywords(query)

        return all_ids.first(limit) if keywords.empty?

        matches = all_ids.select do |id|
          id_lower = id.downcase
          keywords.any? { |kw| id_lower.include?(kw) }
        end

        matches.first(limit)
      end

      # Random strategy: random selection from all available units.
      #
      # @param _query [String] Query string (unused)
      # @param limit [Integer] Max results
      # @return [Array<String>]
      def run_random(_query, limit)
        @metadata_store.all_identifiers.sample(limit)
      end

      # File-level strategy: matches identifiers that look like file paths
      # or class names extracted from the query.
      #
      # @param query [String] Query string
      # @param limit [Integer] Max results
      # @return [Array<String>]
      def run_file_level(query, limit)
        all_ids = @metadata_store.all_identifiers
        keywords = extract_keywords(query)

        return all_ids.first(limit) if keywords.empty?

        # Score each identifier by how many keywords it matches
        scored = all_ids.map do |id|
          id_lower = id.downcase
          score = keywords.count { |kw| id_lower.include?(kw) }
          [id, score]
        end

        scored.select { |_, score| score.positive? }
              .sort_by { |_, score| -score }
              .first(limit)
              .map(&:first)
      end

      # Extract lowercase keywords from a query string.
      #
      # Filters out common stop words and short words.
      #
      # @param query [String] Query text
      # @return [Array<String>] Keywords
      def extract_keywords(query)
        stop_words = %w[the a an is are was were how does do what which where when why
                        this that these those in on at to for of and or but with from by]

        query.downcase
             .scan(/[a-z0-9_]+/)
             .reject { |w| stop_words.include?(w) || w.length < 2 }
      end
    end
  end
end
