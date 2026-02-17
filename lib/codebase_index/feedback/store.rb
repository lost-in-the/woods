# frozen_string_literal: true

require 'json'
require 'fileutils'

module CodebaseIndex
  module Feedback
    # Append-only JSONL file for retrieval feedback: ratings and gap reports.
    #
    # Each line is a JSON object with a `type` field ("rating" or "gap")
    # plus type-specific fields.
    #
    # @example
    #   store = Store.new(path: '/tmp/feedback.jsonl')
    #   store.record_rating(query: "How does User work?", score: 4)
    #   store.record_gap(query: "payments", missing_unit: "PaymentService", unit_type: "service")
    #   store.average_score  # => 4.0
    #
    class Store
      # @param path [String] Path to the JSONL file
      def initialize(path:)
        @path = path
      end

      # Record a retrieval quality rating.
      #
      # @param query [String] The original query
      # @param score [Integer] Rating 1-5
      # @param comment [String, nil] Optional comment
      # @return [void]
      def record_rating(query:, score:, comment: nil)
        unless score.is_a?(Integer) && (1..5).cover?(score)
          raise ArgumentError, "score must be an Integer between 1 and 5, got: #{score.inspect}"
        end

        entry = {
          type: 'rating',
          query: query,
          score: score,
          comment: comment,
          timestamp: Time.now.iso8601
        }
        append(entry)
      end

      # Record a missing unit gap report.
      #
      # @param query [String] The query that had poor results
      # @param missing_unit [String] Identifier of the expected but missing unit
      # @param unit_type [String] Expected type of the missing unit
      # @return [void]
      def record_gap(query:, missing_unit:, unit_type:)
        entry = {
          type: 'gap',
          query: query,
          missing_unit: missing_unit,
          unit_type: unit_type,
          timestamp: Time.now.iso8601
        }
        append(entry)
      end

      # Read all feedback entries.
      #
      # @return [Array<Hash>]
      def all_entries
        return [] unless File.exist?(@path)

        File.readlines(@path).filter_map do |line|
          JSON.parse(line.strip) unless line.strip.empty?
        rescue JSON::ParserError
          nil
        end
      end

      # Filter to rating entries only.
      #
      # @return [Array<Hash>]
      def ratings
        all_entries.select { |e| e['type'] == 'rating' }
      end

      # Filter to gap report entries only.
      #
      # @return [Array<Hash>]
      def gaps
        all_entries.select { |e| e['type'] == 'gap' }
      end

      # Average score across all ratings.
      #
      # @return [Float, nil] Average score, or nil if no ratings
      def average_score
        scores = ratings.map { |r| r['score'] }
        return nil if scores.empty?

        scores.sum.to_f / scores.size
      end

      private

      # Append a JSON entry as a new line.
      #
      # @param entry [Hash]
      # @return [void]
      def append(entry)
        FileUtils.mkdir_p(File.dirname(@path))
        File.open(@path, 'a') do |f|
          f.puts(JSON.generate(entry))
        end
      end
    end
  end
end
