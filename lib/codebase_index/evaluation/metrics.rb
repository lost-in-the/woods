# frozen_string_literal: true

module CodebaseIndex
  module Evaluation
    # Retrieval quality metrics.
    #
    # All methods are stateless pure functions that take arrays of identifiers
    # and return numeric scores.
    #
    module Metrics
      module_function

      # Fraction of top-k results that are relevant.
      #
      # @param retrieved [Array<String>] Retrieved unit identifiers (ordered)
      # @param relevant [Array<String>] Ground-truth relevant identifiers
      # @param cutoff [Integer] Number of top results to consider
      # @return [Float] 0.0 to 1.0
      def precision_at_k(retrieved, relevant, cutoff: 5)
        return 0.0 if retrieved.empty? || relevant.empty?

        top_k = retrieved.first(cutoff)
        relevant_set = relevant.to_set
        hits = top_k.count { |id| relevant_set.include?(id) }
        hits.to_f / cutoff
      end

      # Fraction of relevant items that were retrieved.
      #
      # @param retrieved [Array<String>] Retrieved identifiers
      # @param relevant [Array<String>] Ground-truth relevant identifiers
      # @return [Float] 0.0 to 1.0
      def recall(retrieved, relevant)
        return 0.0 if relevant.empty?

        retrieved_set = retrieved.to_set
        found = relevant.count { |id| retrieved_set.include?(id) }
        found.to_f / relevant.size
      end

      # Mean Reciprocal Rank — inverse of the rank of the first relevant result.
      #
      # @param retrieved [Array<String>] Retrieved identifiers (ordered)
      # @param relevant [Array<String>] Ground-truth relevant identifiers
      # @return [Float] 0.0 to 1.0
      def mrr(retrieved, relevant)
        relevant_set = relevant.to_set
        retrieved.each_with_index do |id, idx|
          return 1.0 / (idx + 1) if relevant_set.include?(id)
        end
        0.0
      end

      # Fraction of required units present in retrieved results.
      #
      # @param retrieved [Array<String>] Retrieved identifiers
      # @param required [Array<String>] Required identifiers (subset of relevant)
      # @return [Float] 0.0 to 1.0
      def context_completeness(retrieved, required)
        return 1.0 if required.empty?

        retrieved_set = retrieved.to_set
        found = required.count { |id| retrieved_set.include?(id) }
        found.to_f / required.size
      end

      # Ratio of relevant tokens to total tokens in context.
      #
      # @param relevant_tokens [Integer] Tokens from relevant units
      # @param total_tokens [Integer] Total tokens in assembled context
      # @return [Float] 0.0 to 1.0
      def token_efficiency(relevant_tokens, total_tokens)
        return 0.0 if total_tokens.zero?

        [relevant_tokens.to_f / total_tokens, 1.0].min
      end
    end
  end
end
