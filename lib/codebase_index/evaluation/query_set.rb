# frozen_string_literal: true

module CodebaseIndex
  module Evaluation
    # Manages a set of evaluation queries with expected results.
    #
    # Each query has a natural language question, a list of expected unit
    # identifiers (ground truth), an intent classification, scope, and tags
    # for filtering. QuerySets can be loaded from and saved to JSON files.
    #
    # @example
    #   qs = QuerySet.load("spec/fixtures/eval_queries.json")
    #   qs.queries.each { |q| puts q.query }
    #   qs.filter(intent: :lookup).size
    #
    class QuerySet
      # A single evaluation query with ground-truth annotations.
      #
      # @!attribute [r] query
      #   @return [String] Natural language query
      # @!attribute [r] expected_units
      #   @return [Array<String>] Expected unit identifiers (ground truth)
      # @!attribute [r] intent
      #   @return [Symbol] Query intent (:lookup, :trace, :explain, :compare)
      # @!attribute [r] scope
      #   @return [Symbol] Query scope (:specific, :bounded, :broad)
      # @!attribute [r] tags
      #   @return [Array<String>] Tags for filtering queries
      Query = Struct.new(:query, :expected_units, :intent, :scope, :tags, keyword_init: true)

      VALID_INTENTS = %i[lookup trace explain compare].freeze
      VALID_SCOPES = %i[specific bounded broad].freeze

      # @return [Array<Query>] The queries in this set
      attr_reader :queries

      # Initialize a QuerySet with an array of queries.
      #
      # @param queries [Array<Query>] Evaluation queries
      def initialize(queries: [])
        @queries = queries
      end

      # Load a QuerySet from a JSON file.
      #
      # @param path [String] Path to JSON file
      # @return [QuerySet] Loaded query set
      # @raise [CodebaseIndex::Error] if the file cannot be read or parsed
      def self.load(path)
        data = JSON.parse(File.read(path))
        queries = data.fetch('queries', []).map { |q| parse_query(q) }
        new(queries: queries)
      rescue JSON::ParserError => e
        raise CodebaseIndex::Error, "Invalid JSON in query set: #{e.message}"
      rescue Errno::ENOENT => e
        raise CodebaseIndex::Error, "Query set file not found: #{e.message}"
      end

      # Save this QuerySet to a JSON file.
      #
      # @param path [String] Path to write JSON file
      # @return [void]
      def save(path)
        data = {
          'queries' => queries.map { |q| serialize_query(q) }
        }
        File.write(path, JSON.pretty_generate(data))
      end

      # Filter queries by intent, scope, or tags.
      #
      # @param intent [Symbol, nil] Filter by intent
      # @param scope [Symbol, nil] Filter by scope
      # @param tags [Array<String>, nil] Filter by tags (any match)
      # @return [Array<Query>] Matching queries
      def filter(intent: nil, scope: nil, tags: nil)
        result = queries
        result = result.select { |q| q.intent == intent } if intent
        result = result.select { |q| q.scope == scope } if scope
        result = result.select { |q| (q.tags & tags).any? } if tags
        result
      end

      # Add a query to this set.
      #
      # @param query [Query] Query to add
      # @return [void]
      # @raise [ArgumentError] if intent or scope is invalid
      def add(query)
        validate_query!(query)
        @queries << query
      end

      # Number of queries in this set.
      #
      # @return [Integer]
      def size
        @queries.size
      end

      private

      # Parse a query hash from JSON into a Query struct.
      #
      # @param hash [Hash] Raw query data
      # @return [Query]
      def self.parse_query(hash)
        Query.new(
          query: hash.fetch('query'),
          expected_units: hash.fetch('expected_units', []),
          intent: hash.fetch('intent', 'lookup').to_sym,
          scope: hash.fetch('scope', 'specific').to_sym,
          tags: hash.fetch('tags', [])
        )
      end

      private_class_method :parse_query

      # Serialize a Query to a hash for JSON output.
      #
      # @param query [Query] Query to serialize
      # @return [Hash]
      def serialize_query(query)
        {
          'query' => query.query,
          'expected_units' => query.expected_units,
          'intent' => query.intent.to_s,
          'scope' => query.scope.to_s,
          'tags' => query.tags
        }
      end

      # Validate intent and scope values.
      #
      # @param query [Query] Query to validate
      # @raise [ArgumentError] if intent or scope is invalid
      def validate_query!(query)
        unless VALID_INTENTS.include?(query.intent)
          raise ArgumentError, "Invalid intent: #{query.intent}. Must be one of #{VALID_INTENTS.join(', ')}"
        end

        return if VALID_SCOPES.include?(query.scope)

        raise ArgumentError, "Invalid scope: #{query.scope}. Must be one of #{VALID_SCOPES.join(', ')}"
      end
    end
  end
end
