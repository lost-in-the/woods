# frozen_string_literal: true

require 'set'

module CodebaseIndex
  module Retrieval
    # Classifies natural language queries to determine retrieval strategy.
    #
    # Uses heuristic pattern matching to determine:
    # - Intent: what the user wants to do
    # - Scope: how broad the search should be
    # - Target type: what kind of code unit to look for
    # - Framework context: whether this is about Rails/gems vs app code
    #
    class QueryClassifier
      # Classification result
      Classification = Struct.new(:intent, :scope, :target_type, :framework_context, :keywords, keyword_init: true)

      INTENTS = %i[understand locate trace debug implement reference compare framework].freeze
      SCOPES = %i[pinpoint focused exploratory comprehensive].freeze

      STOP_WORDS = Set.new(%w[the a an is are was were be been being have has had do does did will would could
                              should may might can shall in on at to for of and or but not with by from as
                              this that these those it its how what when where why who which]).freeze

      # Intent patterns — order matters (first match wins)
      INTENT_PATTERNS = {
        locate: /\b(where|find|which file|locate|look for|search for)\b/i,
        trace: /\b(trace|follow|track|call(s|ed by)|depends on|used by|who calls|what calls)\b/i,
        debug: /\b(bug|error|fix|broken|failing|wrong|issue|problem|crash|exception)\b/i,
        implement: /\b(implement|add|create|build|write|make|generate)\b/i,
        compare: /\b(compare|difference|vs|versus|between|contrast)\b/i,
        # rubocop:disable Layout/LineLength
        framework: /\b(how does rails|what does rails|rails .+ work|work.+\brails\b|in rails\b|activerecord|actioncontroller|activejob)\b/i,
        # rubocop:enable Layout/LineLength
        reference: /\b(show me|what is|what are|list|options for|api|interface|signature)\b/i,
        understand: /\b(how|why|explain|understand|what happens|describe|overview)\b/i
      }.freeze

      # Scope patterns
      SCOPE_PATTERNS = {
        pinpoint: /\b(exactly|specific|this one|just the|only the)\b/i,
        comprehensive: /\b(all|every|entire|whole|complete|everything)\b/i,
        exploratory: /\b(related|around|near|similar|like|associated)\b/i
      }.freeze

      # Target type patterns
      TARGET_PATTERNS = {
        model: /\b(model|activerecord|association|migration|schema|table|column|scope|validation)\b/i,
        controller: /\b(controller|action|route|endpoint|api|request|response|filter|callback)\b/i,
        service: /\b(service|interactor|operation|command|use.?case|business.?logic)\b/i,
        job: /\b(job|worker|background|async|sidekiq|queue|perform)\b/i,
        mailer: /\b(mailer|email|notification|send.?mail)\b/i,
        graphql: /\b(graphql|mutation|query|type|resolver|field|argument|schema)\b/i
      }.freeze

      # Classify a query string
      #
      # @param query [String] Natural language query
      # @return [Classification] Classified query
      def classify(query)
        Classification.new(
          intent: detect_intent(query),
          scope: detect_scope(query),
          target_type: detect_target_type(query),
          framework_context: framework_query?(query),
          keywords: extract_keywords(query)
        )
      end

      private

      # @param query [String]
      # @return [Symbol]
      def detect_intent(query)
        INTENT_PATTERNS.each do |intent, pattern|
          return intent if query.match?(pattern)
        end
        :understand # default
      end

      # @param query [String]
      # @return [Symbol]
      def detect_scope(query)
        SCOPE_PATTERNS.each do |scope, pattern|
          return scope if query.match?(pattern)
        end
        :focused # default
      end

      # @param query [String]
      # @return [Symbol, nil]
      def detect_target_type(query)
        TARGET_PATTERNS.each do |type, pattern|
          return type if query.match?(pattern)
        end
        nil # no specific type detected
      end

      # @param query [String]
      # @return [Boolean]
      def framework_query?(query)
        query.match?(/\b(rails|activerecord|actioncontroller|activejob|actionmailer|activesupport|rack|middleware)\b/i)
      end

      # @param query [String]
      # @return [Array<String>]
      def extract_keywords(query)
        query.downcase
             .gsub(/[^\w\s]/, ' ')
             .split
             .reject { |w| STOP_WORDS.include?(w) || w.length < 2 }
             .uniq
      end
    end
  end
end
